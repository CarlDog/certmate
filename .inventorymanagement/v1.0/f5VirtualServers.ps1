# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "f5VirtualServers"
$ScriptName = $Table
$LogTable = "collectionLogs"
$verboseLogging = $true # Set to $false in production to reduce DEBUG log volume in database
$ErrorActionPreference = 'Continue'

# =====================
# Credential Management (Service Account)
# =====================
$UserName = "svc.prod.maint" # The service account with LTM read access
$Password = "REDACTED_F5_PASSWORD"
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($UserName, $SecurePassword)

# Import required assemblies
Add-Type -AssemblyName System.Web

# =====================
# Enhanced SSL/TLS configuration for F5 compatibility
# =====================
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
[System.Net.ServicePointManager]::CheckCertificateRevocationList = $false
[System.Net.ServicePointManager]::DefaultConnectionLimit = 100
[System.Net.ServicePointManager]::Expect100Continue = $false
[System.Net.ServicePointManager]::UseNagleAlgorithm = $false
[System.Net.ServicePointManager]::EnableDnsRoundRobin = $false
[System.Net.ServicePointManager]::DnsRefreshTimeout = 120000
[System.Net.ServicePointManager]::MaxServicePointIdleTime = 90000

# =====================================================
# LOGGING AND UTILITIES SECTION
# =====================================================

function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $shouldShowDebug = $true
    if ($LogLevel -eq "DEBUG" -and -not $Script:verboseLogging) {
        $shouldShowDebug = $false
    }
    if ($shouldShowDebug) {
        Write-Host ("[{0}] [{1}] {2}" -f $timestamp, $LogLevel, $Message)
    }
    try {
        $logId = [System.Guid]::NewGuid().ToString()
        $dbTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $escapedScriptName = $ScriptName.Replace("'", "''")
        $escapedMessage = $Message.Replace("'", "''")
        $escapedLogLevel = $LogLevel.Replace("'", "''")
        if ($null -eq $AdditionalInfo) {
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]
) VALUES (
    '{0}', '{1}', N'{2}', N'{3}', N'{4}', NULL
)
"@ -f $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage
        } else {
            $escapedAdditionalInfo = $AdditionalInfo.Replace("'", "''")
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]
) VALUES (
    '{0}', '{1}', N'{2}', N'{3}', N'{4}', N'{5}'
)
"@ -f $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage, $escapedAdditionalInfo
        }
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction SilentlyContinue
    } catch {
        $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Write-Host ("[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message)
    }
}

# =====================
# Helper: SQL string escaping
# =====================
function ConvertTo-SqlString {
    param(
        [Parameter(Mandatory=$true)] $obj,
        [Parameter(Mandatory=$true)] [string]$property
    )
    if ($null -eq $obj) { return '' }
    if ($obj.PSObject.Properties[$property]) {
        $val = $obj.$property
        if ($null -eq $val) { return '' }
        $str = [string]$val
        $str = $str -replace "'", "''"
        $str = $str -replace "[\x00-\x1F]", ''
        return $str
    } else {
        return ''
    }
}

# =====================
# Helper: Select best F5 node address (prefer MgmtFQDN, then IP, then Node)
# =====================
function Get-BestF5NodeAddress {
    param(
        [Parameter(Mandatory=$true)]
        $NodeObj
    )
    if ($null -eq $NodeObj) { return $null }
    if ($NodeObj.PSObject.Properties['MgmtFQDN'] -and $NodeObj.MgmtFQDN -and $NodeObj.MgmtFQDN -ne '') {
        return $NodeObj.MgmtFQDN
    } elseif ($NodeObj.PSObject.Properties['IPAddress'] -and $NodeObj.IPAddress -and $NodeObj.IPAddress -ne '') {
        return $NodeObj.IPAddress
    } elseif ($NodeObj.PSObject.Properties['Node'] -and $NodeObj.Node -and $NodeObj.Node -ne '') {
        return $NodeObj.Node
    } elseif ($NodeObj.PSObject.Properties['DisplayName'] -and $NodeObj.DisplayName -and $NodeObj.DisplayName -ne '') {
        return $NodeObj.DisplayName
    }
    return $null
}

# =====================================================
# F5 REST API AND SESSION MANAGEMENT SECTION
# =====================================================

function Invoke-RestMethodOverride {
    [cmdletBinding(DefaultParameterSetName='Anonymous')]
    param (
        [Parameter(Mandatory=$true)][Microsoft.PowerShell.Commands.WebRequestMethod]$Method,
        [Parameter(Mandatory=$true)][uri]$URI,
        [System.Management.Automation.PSCredential]$Credential,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession=(New-Object Microsoft.PowerShell.Commands.WebRequestSession),
        $Body,
        $Headers,
        $ContentType,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )
    
    $retryCount = 0
    $lastError = $null
    
    do {
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                return Invoke-RestMethod @PSBoundParameters -SkipCertificateCheck -TimeoutSec 60
            } else {
                return Invoke-RestMethod @PSBoundParameters -TimeoutSec 60
            }
        }
        catch {
            $lastError = $_
            $retryCount++
            
            # Check if this is a connection-related error that should be retried
            $isRetryableError = $false
            if ($_.Exception.Message -like "*underlying connection was closed*" -or
                $_.Exception.Message -like "*timeout*" -or
                $_.Exception.Message -like "*connection refused*" -or
                $_.Exception.Message -like "*network error*" -or
                $_.Exception.Message -like "*SSL/TLS*") {
                $isRetryableError = $true
            }
            
            if ($isRetryableError -and $retryCount -le $MaxRetries) {
                Write-Warning ("Connection error on attempt {0} for {1}: {2}. Retrying in {3} seconds..." -f $retryCount, $URI, $_.Exception.Message, $RetryDelaySeconds)
                Start-Sleep -Seconds $RetryDelaySeconds
                # Exponential backoff
                $RetryDelaySeconds = $RetryDelaySeconds * 2
            }
            else {
                # Either not retryable or max retries exceeded
                throw $lastError
            }
        }
    } while ($retryCount -le $MaxRetries)
    
    # Should never reach here, but just in case
    throw $lastError
}

function New-F5Session {
    [cmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$LTMName,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [switch]$Default,
        [switch]$PassThru,
        [ValidateRange(300,36000)][int]$TokenLifespan=1200
    )
    $LTMCredentials = $null
    if ($PSBoundParameters.ContainsKey('Credential') -and $Credential) {
        $LTMCredentials = $Credential
    } elseif ($env:USERNAME) {
        try {
            $LTMCredentials = New-Object System.Management.Automation.PSCredential ($env:USERNAME, (ConvertTo-SecureString "" -AsPlainText -Force))
        } catch {
            $LTMCredentials = $null
        }
    }
    Write-Log -Message ("New-F5Session using credentials: {0}" -f $LTMCredentials.UserName) -LogLevel "DEBUG"
    if ($null -eq $LTMCredentials) {
        Write-Log -Message ("No credentials available for F5 session. Running as: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "ERROR"
        throw "No credentials available for F5 session."
    }
    $BaseURL = "https://{0}/mgmt/tm/ltm/" -f $LTMName
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $AuthURL = ("https://{0}/mgmt/shared/authn/login" -f $LTMName)
    $JSONBody = @{username = $LTMCredentials.username; password=$LTMCredentials.GetNetworkCredential().password; loginProviderName='tmos'} | ConvertTo-Json
    $Token = $null
    try {
        $Result = Invoke-RestMethodOverride -Method POST -Uri $AuthURL -Body $JSONBody -Credential $LTMCredentials -ContentType 'application/json'
        Write-Log -Message ("Raw token object returned: {0}" -f ($Result | ConvertTo-Json -Compress)) -LogLevel "DEBUG"
        $Token = $Result.token.token
        $session.Headers.Add('X-F5-Auth-Token', $Token)
        if ($Result.token.uuid) { $TokenReference = $Result.token.uuid } else { $TokenReference = $Result.token.name }
        if ($TokenLifespan -ne 1200) {
            $Body = @{ timeout = $TokenLifespan  }  | ConvertTo-Json
            $Headers = @{ 'X-F5-Auth-Token' = $Token }
            Invoke-RestMethodOverride -Method Patch -Uri https://$LTMName/mgmt/shared/authz/tokens/$TokenReference -Headers $Headers -Body $Body -WebSession $session | Out-Null
        }
        $ts = New-TimeSpan -Minutes ($TokenLifespan/60)
        $date = Get-Date -Date $Result.token.startTime
        $ExpirationTime = $date + $ts
        $session.Headers.Add('Token-Expiration', $ExpirationTime)
    } catch {
        try {
            Invoke-WebRequest -Uri $BaseURL -ErrorVariable LTMError -TimeoutSec 3
        } catch {
            if ($LTMError[0] -notmatch 'Unauthorized') { Throw ("The specified LTM name {0} is not valid." -f $LTMName) }
        }
        $Credential = $LTMCredentials
    }
    $newSession = [pscustomobject]@{
        Name       = $LTMName
        BaseURL    = $BaseURL
        Credential = $Credential
        WebSession = $session
        Token      = $Token
    } | Add-Member -Name GetLink -MemberType ScriptMethod {
        param($Link)
        $Link -replace 'localhost', $this.Name
    } -PassThru
    $VersionURL = ("{0}sys/version/" -f ($BaseURL -replace 'ltm/$', ''))
    $JSON = Invoke-RestMethodOverride -Method Get -Uri $VersionURL -WebSession $session
    $version = '0.0.0.0'
    $JSONStr = $JSON | Out-String
    if ($JSONStr -match '([0-9]+\.?){3,4}') { $version = [Regex]::Match($JSONStr, '([0-9]+\.?){3,4}').Value }
    $newSession | Add-Member -Name LTMVersion -Value ([Version]$version) -MemberType NoteProperty
    if ($Default -or !($Script:F5Session)) { $Script:F5Session = $newSession }
    if ($PassThru) { return $newSession } else { $null }
}

function Get-F5VirtualServer {
    [cmdletBinding()]
    param (
        $Session,
        [Parameter(ValueFromPipeline)]
        [string[]]$Name='',
        [string]$Partition = "Common"
    )
    begin {
        if ($null -eq $Session) {
            throw "No F5 session specified"
        }
    }
    process {
        try {
            if ($Name -and $Name -ne '') {
                $allVS = @()
                foreach ($vsName in $Name) {
                    try {
                        $encodedName = [System.Web.HttpUtility]::UrlEncode($vsName)
                        $uri = "{0}virtual/{1}?$select=name,fullPath,partition,destination,ipProtocol,enabled,disabled,description,source,profilesReference,vlans,policiesReference,sourceAddressTranslation,snatpool,translateAddress,translatePort,mask,rateLimit,rateLimitDstMask,rateLimitMode,rateLimitSrcMask,mirror,persistenceReference,defaultPersistenceProfile,fallbackPersistenceProfile,rules,trafficGroup" -f $Session.BaseURL, $encodedName
                        Write-Log -Message ("Requesting specific virtual server: {0}" -f $uri) -LogLevel "DEBUG"
                        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                        if ($result) {
                            $result | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                            $allVS += $result
                        }
                    } catch {
                        Write-Log -Message ("Failed to get virtual server '{0}': {1}" -f $vsName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                }
                return $allVS
            } else {
                $uri = $Session.BaseURL + "virtual"
                if ($Partition -and $Partition -ne '') {
                    $uri += "?`$filter=partition+eq+$Partition"
                }
                Write-Log -Message ("Requesting all virtual servers: {0}" -f $uri) -LogLevel "DEBUG"
                $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                if ($result -and $result.items) {
                    Write-Log -Message ("Retrieved {0} virtual servers from F5" -f $result.items.Count) -LogLevel "INFO"
                    foreach ($item in $result.items) {
                        $item | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                    }
                    return $result.items
                } else {
                    Write-Log -Message ("No virtual servers found or result is empty") -LogLevel "INFO"
                    return @()
                }
            }
        } catch {
            $errorMsg = "Error retrieving virtual server: {0}" -f $_.Exception.Message
            Write-Log -Message $errorMsg -LogLevel "ERROR"
            return $null
        }
    }
}

function Disconnect-F5LTM {
    [cmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Session
    )
    try {
        if ($Session.Token) {
            $uri = ("https://{0}/mgmt/shared/authz/tokens/{1}" -f $Session.Name, $Session.Token)
            $Headers = @{
                'X-F5-Auth-Token' = $Session.Token
            }
            try {
                Invoke-RestMethodOverride -Method DELETE -Uri $uri -Headers $Headers -WebSession $Session.WebSession -ErrorAction Stop | Out-Null
                return $true
            } catch {
                Write-Warning ("Could not delete token for session: {0}" -f $_)
                return $false
            }
        }
        return $true
    } catch {
        Write-Warning ("Error disconnecting from F5 LTM: {0}" -f $_)
        return $false
    }
}

# =====================================================
# VIRTUAL SERVER COLLECTION AND PROCESSING SECTION
# =====================================================

function Test-ValidF5VirtualServerObject {
    param([object]$obj)
    
    if ($null -eq $obj) {
        Write-Log -Message ("Virtual server object is null") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not ($obj -is [PSCustomObject])) {
        Write-Log -Message ("Virtual server object is not PSCustomObject: {0}" -f $obj.GetType().FullName) -LogLevel "DEBUG"
        return $false
    }
    
    if ($obj.PSObject.Properties.Count -eq 0) {
        Write-Log -Message ("Virtual server object has no properties") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['name']) {
        Write-Log -Message ("Virtual server object missing name property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.name)) {
        Write-Log -Message ("Virtual server name is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['F5Node']) {
        Write-Log -Message ("Virtual server object missing F5Node property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.F5Node)) {
        Write-Log -Message ("Virtual server F5Node is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    return $true
}

# =====================
# Virtual Server Collection
# =====================
function Get-F5VirtualServerMetadata {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$F5Nodes
    )
    $allVS = @()
    foreach ($cluster in $F5Nodes.Keys) {
        foreach ($nodeObj in $F5Nodes[$cluster]) {
            $connectName = Get-BestF5NodeAddress -NodeObj $nodeObj
            if ($null -eq $connectName) {
                Write-Log -Message ("No valid connection address found for node: {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Processing F5 node: {0} (using address: {1})" -f $nodeObj.DisplayName, $connectName) -LogLevel "INFO"
            try {
                $f5Session = New-F5Session -LTMName $connectName -Credential $Credential -ErrorAction Stop -PassThru -TokenLifespan 1200
                if ($null -eq $f5Session) {
                    Write-Log -Message ("Failed to create session for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    continue
                }
                # Use enhanced bulk API with subcollections for better performance
                $virtualServers = Get-F5VirtualServerWithSubcollections -Session $f5Session -ExpandSubcollections -ErrorAction Stop
                if ($null -eq $virtualServers) {
                    Write-Log -Message ("No virtual servers returned for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
                    continue
                }
                Write-Log -Message ("Retrieved {0} virtual servers from {1} using enhanced bulk API" -f $virtualServers.Count, $nodeObj.DisplayName) -LogLevel "INFO"
                
                foreach ($vs in $virtualServers) {
                    if ($null -eq $vs -or $vs -is [string] -or -not ($vs -is [PSCustomObject])) {
                        Write-Log -Message ("Skipping invalid virtual server object") -LogLevel "WARNING"
                        continue
                    }
                    $vs | Add-Member -NotePropertyName "F5Node" -NotePropertyValue $nodeObj.Node -Force
                    $vs | Add-Member -NotePropertyName "F5DisplayName" -NotePropertyValue $nodeObj.DisplayName -Force
                    $vs | Add-Member -NotePropertyName "F5Cluster" -NotePropertyValue $cluster -Force
                    
                    # Process embedded data if available
                    $embeddedData = ConvertFrom-F5EmbeddedVirtualServerData -VirtualServer $vs
                    if ($embeddedData) {
                        $vs | Add-Member -NotePropertyName "EmbeddedData" -NotePropertyValue $embeddedData -Force
                        Write-Log -Message ("Virtual server '{0}' has enhanced embedded data from bulk API" -f $vs.name) -LogLevel "INFO"
                    }
                    
                    # Validate the virtual server object before adding to collection
                    if (Test-ValidF5VirtualServerObject $vs) {
                        $allVS += $vs
                    } else {
                        Write-Log -Message ("Skipping invalid virtual server: {0}" -f ($vs | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                    }
                }
                Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
            } catch {
                $errMsg = $_.Exception.Message
                Write-Log -Message ("ERROR processing node {0}: {1}" -f $nodeObj.DisplayName, $errMsg) -LogLevel "ERROR"
                if ($f5Session) {
                    try { Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }
    Write-Log -Message ("Virtual server collection complete. Found {0} total virtual servers." -f $allVS.Count) -LogLevel "INFO"
    return $allVS
}

# =====================================================
# DATABASE ACCESS SECTION
# =====================================================

function Get-F5NodesFromDB {
    try {
        $query = "SELECT Cluster, Node, DisplayName, MgmtFQDN, IPAddress, Location, Environment, DeviceType, IsActive, LastSeen FROM f5Nodes"
        $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction Stop
        $f5Nodes = @{}
        foreach ($row in $results) {
            if (-not $f5Nodes.ContainsKey($row.Cluster)) { $f5Nodes[$row.Cluster] = @() }
            $f5Nodes[$row.Cluster] += [PSCustomObject]@{
                Node        = $row.Node
                DisplayName = $row.DisplayName
                MgmtFQDN    = $row.MgmtFQDN
                IPAddress   = $row.IPAddress
                Location    = $row.Location
                Environment = $row.Environment
                DeviceType  = $row.DeviceType
                IsActive    = $row.IsActive
                LastSeen    = $row.LastSeen
            }
        }
        return $f5Nodes
    } catch {
        Write-Log -Message ("Failed to retrieve F5 nodes from database: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
        throw
    }
}

function Update-F5VirtualServerDatabase {
    param (
        [Parameter(Mandatory=$true)]
        [array]$virtualServers
    )
    if ($null -eq $virtualServers) {
        Write-Log -Message ("virtualServers parameter is null") -LogLevel "ERROR"
        return
    }
    try {
        $insertCount = 0
        $skippedCount = 0
        if ($virtualServers.Count -eq 0) {
            Write-Log -Message ("No F5 virtual servers found to insert into the database") -LogLevel "WARNING"
            return
        }
        Write-Log -Message ("Processing {0} F5 virtual servers for database update" -f $virtualServers.Count) -LogLevel "INFO"
        foreach ($vs in $virtualServers) {
            if (-not (Test-ValidF5VirtualServerObject $vs)) {
                Write-Log -Message ("SKIP: Invalid virtual server object: {0}" -f ($vs | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                $skippedCount++
                continue
            }
            $escapedF5Node = ConvertTo-SqlString $vs 'F5Node'
            $escapedName = ConvertTo-SqlString $vs 'name'
            $escapedFullPath = ConvertTo-SqlString $vs 'fullPath'
            $escapedPartition = ConvertTo-SqlString $vs 'partition'
            
            # Normalize destination path (remove /Common/ prefix)
            $normalizedDestination = ""
            if ($vs.PSObject.Properties['destination'] -and $vs.destination) {
                $normalizedDestination = Format-F5Path $vs.destination
            }
            $escapedDestination = $normalizedDestination.Replace("'", "''").Replace("[\x00-\x1F]", '')
            
            $escapedIpProtocol = ConvertTo-SqlString $vs 'ipProtocol'
            $escapedEnabled = ConvertTo-SqlString $vs 'enabled'
            $escapedDisabled = ConvertTo-SqlString $vs 'disabled'
            $escapedDescription = ConvertTo-SqlString $vs 'description'
            $escapedSource = ConvertTo-SqlString $vs 'source'
            
            # Handle nested/array fields as JSON (following f5SSLProfiles.ps1 pattern)
            $profilesInfo = ""
            if ($vs.PSObject.Properties['profilesReference'] -and $vs.profilesReference) {
                $profilesInfo = ($vs.profilesReference | ConvertTo-Json -Compress)
            }
            $escapedProfiles = $profilesInfo.Replace("'", "''")
            
            $vlansInfo = ""
            if ($vs.PSObject.Properties['vlans'] -and $vs.vlans) {
                $vlansInfo = ($vs.vlans | ConvertTo-Json -Compress)
            }
            $escapedVlans = $vlansInfo.Replace("'", "''")
            
            $policiesInfo = ""
            if ($vs.PSObject.Properties['policiesReference'] -and $vs.policiesReference) {
                $policiesInfo = ($vs.policiesReference | ConvertTo-Json -Compress)
            }
            $escapedPolicies = $policiesInfo.Replace("'", "''")
            
            $sourceAddressTranslationInfo = ""
            if ($vs.PSObject.Properties['sourceAddressTranslation'] -and $vs.sourceAddressTranslation) {
                $sourceAddressTranslationInfo = ($vs.sourceAddressTranslation | ConvertTo-Json -Compress)
            }
            $escapedSourceAddressTranslation = $sourceAddressTranslationInfo.Replace("'", "''")
            
            $escapedSnatpool = ConvertTo-SqlString $vs 'snatpool'
            $escapedTranslateAddress = ConvertTo-SqlString $vs 'translateAddress'
            $escapedTranslatePort = ConvertTo-SqlString $vs 'translatePort'
            $escapedMask = ConvertTo-SqlString $vs 'mask'
            $escapedRateLimit = ConvertTo-SqlString $vs 'rateLimit'
            $escapedRateLimitDstMask = ConvertTo-SqlString $vs 'rateLimitDstMask'
            $escapedRateLimitMode = ConvertTo-SqlString $vs 'rateLimitMode'
            $escapedRateLimitSrcMask = ConvertTo-SqlString $vs 'rateLimitSrcMask'
            $escapedMirror = ConvertTo-SqlString $vs 'mirror'
            
            $persistenceInfo = ""
            if ($vs.PSObject.Properties['persistenceReference'] -and $vs.persistenceReference) {
                $persistenceInfo = ($vs.persistenceReference | ConvertTo-Json -Compress)
            }
            $escapedPersistence = $persistenceInfo.Replace("'", "''")
            
            # Normalize persistence profile paths (remove /Common/ prefix)
            $normalizedDefaultPersistence = ""
            if ($vs.PSObject.Properties['defaultPersistenceProfile'] -and $vs.defaultPersistenceProfile) {
                $normalizedDefaultPersistence = Format-F5Path $vs.defaultPersistenceProfile
            }
            $escapedDefaultPersistenceProfile = $normalizedDefaultPersistence.Replace("'", "''").Replace("[\x00-\x1F]", '')
            
            $normalizedFallbackPersistence = ""
            if ($vs.PSObject.Properties['fallbackPersistenceProfile'] -and $vs.fallbackPersistenceProfile) {
                $normalizedFallbackPersistence = Format-F5Path $vs.fallbackPersistenceProfile
            }
            $escapedFallbackPersistenceProfile = $normalizedFallbackPersistence.Replace("'", "''").Replace("[\x00-\x1F]", '')
            
            $rulesInfo = ""
            if ($vs.PSObject.Properties['rules'] -and $vs.rules) {
                $rulesInfo = ($vs.rules | ConvertTo-Json -Compress)
            }
            $escapedRules = $rulesInfo.Replace("'", "''")
            
            # Normalize traffic group path (remove /Common/ prefix)
            $normalizedTrafficGroup = ""
            if ($vs.PSObject.Properties['trafficGroup'] -and $vs.trafficGroup) {
                $normalizedTrafficGroup = Format-F5Path $vs.trafficGroup
            }
            $escapedTrafficGroup = $normalizedTrafficGroup.Replace("'", "''").Replace("[\x00-\x1F]", '')
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
            
            # Log key field values for debugging (showing normalized destination)
            Write-Log -Message ("Processing VS: F5Node='{0}', Name='{1}', FullPath='{2}', Destination='{3}' (normalized from '{4}')" -f $escapedF5Node, $escapedName, $escapedFullPath, $escapedDestination, $vs.destination) -LogLevel "DEBUG"
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedF5Node' AS [F5Node],
    N'$escapedName' AS [Name]
) AS Source
ON Target.[F5Node] = Source.[F5Node] AND Target.[Name] = Source.[Name]
WHEN MATCHED THEN
    UPDATE SET
        [FullPath] = N'$escapedFullPath',
        [Partition] = NULLIF(N'$escapedPartition', ''),
        [Destination] = NULLIF(N'$escapedDestination', ''),
        [IpProtocol] = NULLIF(N'$escapedIpProtocol', ''),
        [Enabled] = NULLIF(N'$escapedEnabled', ''),
        [Disabled] = NULLIF(N'$escapedDisabled', ''),
        [Description] = NULLIF(N'$escapedDescription', ''),
        [Source] = NULLIF(N'$escapedSource', ''),
        [ProfilesReference] = NULLIF(N'$escapedProfiles', ''),
        [Vlans] = NULLIF(N'$escapedVlans', ''),
        [PoliciesReference] = NULLIF(N'$escapedPolicies', ''),
        [SourceAddressTranslation] = NULLIF(N'$escapedSourceAddressTranslation', ''),
        [Snatpool] = NULLIF(N'$escapedSnatpool', ''),
        [TranslateAddress] = NULLIF(N'$escapedTranslateAddress', ''),
        [TranslatePort] = NULLIF(N'$escapedTranslatePort', ''),
        [Mask] = NULLIF(N'$escapedMask', ''),
        [RateLimit] = NULLIF(N'$escapedRateLimit', ''),
        [RateLimitDstMask] = NULLIF(N'$escapedRateLimitDstMask', ''),
        [RateLimitMode] = NULLIF(N'$escapedRateLimitMode', ''),
        [RateLimitSrcMask] = NULLIF(N'$escapedRateLimitSrcMask', ''),
        [Mirror] = NULLIF(N'$escapedMirror', ''),
        [PersistenceReference] = NULLIF(N'$escapedPersistence', ''),
        [DefaultPersistenceProfile] = NULLIF(N'$escapedDefaultPersistenceProfile', ''),
        [FallbackPersistenceProfile] = NULLIF(N'$escapedFallbackPersistenceProfile', ''),
        [Rules] = NULLIF(N'$escapedRules', ''),
        [TrafficGroup] = NULLIF(N'$escapedTrafficGroup', ''),
        [DateAdded] = '$dateAdded'
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [Destination], [IpProtocol], [Enabled], [Disabled], [Description], [Source], [ProfilesReference], [Vlans], [PoliciesReference], [SourceAddressTranslation], [Snatpool], [TranslateAddress], [TranslatePort], [Mask], [RateLimit], [RateLimitDstMask], [RateLimitMode], [RateLimitSrcMask], [Mirror], [PersistenceReference], [DefaultPersistenceProfile], [FallbackPersistenceProfile], [Rules], [TrafficGroup], [DateAdded])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', NULLIF(N'$escapedPartition', ''), NULLIF(N'$escapedDestination', ''), NULLIF(N'$escapedIpProtocol', ''), NULLIF(N'$escapedEnabled', ''), NULLIF(N'$escapedDisabled', ''), NULLIF(N'$escapedDescription', ''), NULLIF(N'$escapedSource', ''), NULLIF(N'$escapedProfiles', ''), NULLIF(N'$escapedVlans', ''), NULLIF(N'$escapedPolicies', ''), NULLIF(N'$escapedSourceAddressTranslation', ''), NULLIF(N'$escapedSnatpool', ''), NULLIF(N'$escapedTranslateAddress', ''), NULLIF(N'$escapedTranslatePort', ''), NULLIF(N'$escapedMask', ''), NULLIF(N'$escapedRateLimit', ''), NULLIF(N'$escapedRateLimitDstMask', ''), NULLIF(N'$escapedRateLimitMode', ''), NULLIF(N'$escapedRateLimitSrcMask', ''), NULLIF(N'$escapedMirror', ''), NULLIF(N'$escapedPersistence', ''), NULLIF(N'$escapedDefaultPersistenceProfile', ''), NULLIF(N'$escapedFallbackPersistenceProfile', ''), NULLIF(N'$escapedRules', ''), NULLIF(N'$escapedTrafficGroup', ''), '$dateAdded');
"@
            try {
                Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery -ErrorAction Stop
                $insertCount++
                Write-Log -Message ("Successfully processed virtual server: {0} on node {1}" -f $vs.name, $vs.F5Node) -LogLevel "DEBUG"
            } catch {
                $sqlError = $_.Exception.Message
                Write-Log -Message ("SQL ERROR: {0} | Query: {1}" -f $sqlError, $mergeQuery) -LogLevel "ERROR"
            }
        }
        Write-Log -Message ("Successfully upserted {0} F5 virtual servers into the database. Skipped {1} with invalid data." -f $insertCount, $skippedCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update F5 virtual server database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

# =====================================================
# ENHANCED BULK API FUNCTIONALITY SECTION
# =====================================================

function Get-F5VirtualServerWithSubcollections {
    [cmdletBinding()]
    param (
        $Session,
        [string]$Partition = "Common",
        [switch]$ExpandSubcollections
    )
    
    if ($null -eq $Session) {
        Write-Log -Message ("No F5 session specified for virtual servers") -LogLevel "WARNING"
        return @()
    }
    
    try {
        $uri = $Session.BaseURL + "virtual"
        
        # Add partition filter if specified
        $queryParams = @()
        if ($Partition -and $Partition -ne '') {
            $queryParams += "`$filter=partition+eq+$Partition"
        }
        
        # Add expandSubcollections parameter for bulk data retrieval
        if ($ExpandSubcollections) {
            $queryParams += "expandSubcollections=true"
        }
        
        if ($queryParams.Count -gt 0) {
            $uri += "?" + ($queryParams -join "&")
        }
        
        Write-Log -Message ("Enhanced bulk API request for virtual servers: {0}" -f $uri) -LogLevel "DEBUG"
        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
        
        if ($result -and $result.items) {
            Write-Log -Message ("Retrieved {0} virtual servers with enhanced bulk API (expandSubcollections)" -f $result.items.Count) -LogLevel "INFO"
            
            # Process each virtual server to extract embedded data
            foreach ($vs in $result.items) {
                $vs | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                
                # Check for embedded subcollections and mark them
                if ($ExpandSubcollections) {
                    # Check for direct embedded data or expanded Reference objects
                    if (($vs.PSObject.Properties['profiles'] -and $vs.profiles) -or 
                        ($vs.PSObject.Properties['profilesReference'] -and $vs.profilesReference -and $vs.profilesReference.PSObject.Properties['items'])) {
                        $vs | Add-Member -MemberType NoteProperty -Name "HasEmbeddedProfiles" -Value $true -Force
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Virtual server '{0}' has embedded/expanded profiles data" -f $vs.name) -LogLevel "DEBUG"
                        }
                    }
                    
                    if ($vs.PSObject.Properties['rules'] -and $vs.rules) {
                        $vs | Add-Member -MemberType NoteProperty -Name "HasEmbeddedRules" -Value $true -Force
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Virtual server '{0}' has embedded rules data" -f $vs.name) -LogLevel "DEBUG"
                        }
                    }
                    
                    if (($vs.PSObject.Properties['policies'] -and $vs.policies) -or 
                        ($vs.PSObject.Properties['policiesReference'] -and $vs.policiesReference -and $vs.policiesReference.PSObject.Properties['items'])) {
                        $vs | Add-Member -MemberType NoteProperty -Name "HasEmbeddedPolicies" -Value $true -Force
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Virtual server '{0}' has embedded/expanded policies data" -f $vs.name) -LogLevel "DEBUG"
                        }
                    }
                    
                    if ($vs.PSObject.Properties['vlans'] -and $vs.vlans) {
                        $vs | Add-Member -MemberType NoteProperty -Name "HasEmbeddedVlans" -Value $true -Force
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Virtual server '{0}' has embedded VLANs data" -f $vs.name) -LogLevel "DEBUG"
                        }
                    }
                    
                    if ($vs.PSObject.Properties['persistenceReference'] -and $vs.persistenceReference -and $vs.persistenceReference.PSObject.Properties['items']) {
                        $vs | Add-Member -MemberType NoteProperty -Name "HasEmbeddedPersistence" -Value $true -Force
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Virtual server '{0}' has expanded persistence data" -f $vs.name) -LogLevel "DEBUG"
                        }
                    }
                }
            }
            
            return $result.items
        } else {
            Write-Log -Message ("No virtual servers found or result is empty") -LogLevel "INFO"
            return @()
        }
    } catch {
        $errorMsg = "Error retrieving virtual servers with bulk API: {0}" -f $_.Exception.Message
        Write-Log -Message $errorMsg -LogLevel "ERROR"
        
        # Fallback to individual API calls if bulk fails
        Write-Log -Message ("Falling back to individual API calls") -LogLevel "WARNING"
        return Get-F5VirtualServer -Session $Session -Partition $Partition
    }
}

function ConvertFrom-F5EmbeddedVirtualServerData {
    [cmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        $VirtualServer
    )
    
    # Debug: Log all virtual server properties to understand the structure
    if ($Script:verboseLogging) {
        $vsProps = $VirtualServer.PSObject.Properties.Name -join ', '
        Write-Log -Message ("Virtual server '{0}' has properties: {1}" -f $VirtualServer.name, $vsProps) -LogLevel "DEBUG"
    }
    
    $enhancedData = @{
        hasEmbeddedData = $false
        profiles = @()
        rules = @()
        policies = @()
        vlans = @()
        persistence = @()
        source = "individual-api"
    }
    
    # Method 1: Check for embedded profiles data (both direct and Reference formats)
    if ($VirtualServer.PSObject.Properties['profiles'] -and $VirtualServer.profiles) {
        if ($VirtualServer.profiles -is [Array] -and $VirtualServer.profiles.Count -gt 0) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded profiles for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.profiles = $VirtualServer.profiles
            $enhancedData.hasEmbeddedData = $true
            $enhancedData.source = "embedded-bulk-api"
        } elseif ($VirtualServer.profiles.PSObject.Properties['items'] -and $VirtualServer.profiles.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded profiles.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.profiles = $VirtualServer.profiles.items
            $enhancedData.hasEmbeddedData = $true
            $enhancedData.source = "embedded-bulk-api-items"
        }
    }
    # Also check profilesReference (F5 typically uses Reference properties)
    elseif ($VirtualServer.PSObject.Properties['profilesReference'] -and $VirtualServer.profilesReference) {
        if ($VirtualServer.profilesReference.PSObject.Properties['items'] -and $VirtualServer.profilesReference.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing expanded profilesReference.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.profiles = $VirtualServer.profilesReference.items
            $enhancedData.hasEmbeddedData = $true
            $enhancedData.source = "expanded-reference-api"
        }
    }
    
    # Method 2: Check for embedded rules data
    if ($VirtualServer.PSObject.Properties['rules'] -and $VirtualServer.rules) {
        if ($VirtualServer.rules -is [Array] -and $VirtualServer.rules.Count -gt 0) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded rules for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.rules = $VirtualServer.rules
            $enhancedData.hasEmbeddedData = $true
        } elseif ($VirtualServer.rules.PSObject.Properties['items'] -and $VirtualServer.rules.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded rules.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.rules = $VirtualServer.rules.items
            $enhancedData.hasEmbeddedData = $true
        }
    }
    
    # Method 3: Check for embedded policies data (both direct and Reference formats)
    if ($VirtualServer.PSObject.Properties['policies'] -and $VirtualServer.policies) {
        if ($VirtualServer.policies -is [Array] -and $VirtualServer.policies.Count -gt 0) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded policies for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.policies = $VirtualServer.policies
            $enhancedData.hasEmbeddedData = $true
        } elseif ($VirtualServer.policies.PSObject.Properties['items'] -and $VirtualServer.policies.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded policies.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.policies = $VirtualServer.policies.items
            $enhancedData.hasEmbeddedData = $true
        }
    }
    # Also check policiesReference 
    elseif ($VirtualServer.PSObject.Properties['policiesReference'] -and $VirtualServer.policiesReference) {
        if ($VirtualServer.policiesReference.PSObject.Properties['items'] -and $VirtualServer.policiesReference.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing expanded policiesReference.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.policies = $VirtualServer.policiesReference.items
            $enhancedData.hasEmbeddedData = $true
            $enhancedData.source = "expanded-reference-api"
        }
    }
    
    # Method 4: Check for VLANs data
    if ($VirtualServer.PSObject.Properties['vlans'] -and $VirtualServer.vlans) {
        if ($VirtualServer.vlans -is [Array] -and $VirtualServer.vlans.Count -gt 0) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing embedded VLANs for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.vlans = $VirtualServer.vlans
            $enhancedData.hasEmbeddedData = $true
        }
    }
    
    # Method 5: Check for persistence data
    if ($VirtualServer.PSObject.Properties['persistenceReference'] -and $VirtualServer.persistenceReference) {
        if ($VirtualServer.persistenceReference.PSObject.Properties['items'] -and $VirtualServer.persistenceReference.items) {
            if ($Script:verboseLogging) {
                Write-Log -Message ("Processing expanded persistenceReference.items for virtual server '{0}'" -f $VirtualServer.name) -LogLevel "DEBUG"
            }
            $enhancedData.persistence = $VirtualServer.persistenceReference.items
            $enhancedData.hasEmbeddedData = $true
            $enhancedData.source = "expanded-reference-api"
        }
    }
    
    if ($enhancedData.hasEmbeddedData) {
        Write-Log -Message ("Found embedded data for virtual server '{0}' using {1}: Profiles={2}, Rules={3}, Policies={4}, VLANs={5}, Persistence={6}" -f $VirtualServer.name, $enhancedData.source, $enhancedData.profiles.Count, $enhancedData.rules.Count, $enhancedData.policies.Count, $enhancedData.vlans.Count, $enhancedData.persistence.Count) -LogLevel "INFO"
        return $enhancedData
    } else {
        Write-Log -Message ("No embedded data found for virtual server '{0}' - will use standard API references" -f $VirtualServer.name) -LogLevel "DEBUG"
        return $null
    }
}

# =====================
# Helper: Normalize F5 object paths (remove /Common/ prefix)
# =====================
function Format-F5Path {
    param([string]$Path)
    if ($null -eq $Path -or $Path -eq "" -or $Path -eq "none") { 
        return $Path 
    }
    
    # Handle F5 object paths (e.g., "/Common/10.150.48.115:389")
    if ($Path -match "^/Common/(.+)$") {
        return $matches[1]
    }
    
    return $Path
}

# =====================================================
# MAIN SCRIPT EXECUTION SECTION
# =====================================================

try {
    Write-Log -Message ("Starting F5 virtual server collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    $Script:verboseLogging = $verboseLogging
    Write-Log -Message ("Loading F5 nodes from database") -LogLevel "INFO"
    $f5Nodes = Get-F5NodesFromDB
    if ($null -eq $f5Nodes -or $f5Nodes.Count -eq 0) {
        Write-Log -Message ("No F5 nodes found in database. Please check f5Nodes table.") -LogLevel "ERROR"
        exit 1
    }
    $totalNodes = 0
    foreach ($nodeGroup in $f5Nodes.Keys) {
        $totalNodes += $f5Nodes[$nodeGroup].Count
    }
    Write-Log -Message ("Found {0} F5 clusters with {1} total nodes to process" -f $f5Nodes.Keys.Count, $totalNodes) -LogLevel "INFO"
    Write-Log -Message ("Starting virtual server collection from F5 nodes") -LogLevel "INFO"
    $virtualServers = Get-F5VirtualServerMetadata -F5Nodes $f5Nodes
    if ($null -eq $virtualServers) {
        Write-Log -Message ("Virtual server collection returned null. Check previous errors.") -LogLevel "ERROR"
    } elseif ($virtualServers.Count -eq 0) {
        Write-Log -Message ("No virtual servers found across any F5 nodes. Check for connection issues.") -LogLevel "WARNING"
    } else {
        Write-Log -Message ("Collected {0} virtual servers from F5 nodes" -f $virtualServers.Count) -LogLevel "INFO"
        # Log a sample of the normalized virtual server object for inspection
        $sampleVS = $virtualServers | Select-Object -First 1
        if ($sampleVS) {
            $sampleJson = $sampleVS | ConvertTo-Json -Compress
            Write-Log -Message ("Sample normalized virtual server object: {0}" -f $sampleJson) -LogLevel "DEBUG"
        }
        # Update the database with the collected virtual servers
        Update-F5VirtualServerDatabase -virtualServers $virtualServers
    }
    Write-Log -Message ("F5 virtual server collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 virtual server collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}
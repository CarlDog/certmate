# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "f5SSLProfiles"
$ScriptName = $Table
$LogTable = "collectionLogs"
$verboseLogging = $false
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

# =====================
# Load F5 Nodes from Database
# =====================
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

# =====================
# Logging Function
# =====================
function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    # Only display DEBUG messages to console if verbose logging is enabled
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
# Helper: Normalize thumbprint (remove colons, uppercase)
# =====================
function Format-Thumbprint {
    param([string]$Thumbprint)
    if ($null -eq $Thumbprint -or $Thumbprint -eq "" -or $Thumbprint -eq "none") { 
        return $null 
    }
    
    # Handle F5 certificate paths (e.g., "/Common/star.cir2.com.crt")
    if ($Thumbprint -match "^/Common/(.+)$") {
        return $matches[1]
    }
    
    # Remove SHA256/ prefix if present
    $normalized = $Thumbprint
    if ($normalized -match "^SHA256/(.+)$") {
        $normalized = $matches[1]
    }
    
    # Remove colons
    $normalized = $normalized -replace ":", ""
    
    # Convert to uppercase for consistency
    $normalized = $normalized.ToUpper()
    
    return $normalized
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
        # Escape single quotes for SQL
        $str = $str -replace "'", "''"
        # Remove null bytes and control chars
        $str = $str -replace "[\x00-\x1F]", ''
        return $str
    } else {
        return ''
    }
}

# =====================
# Helper: Date/time conversion with multiple format support
# =====================
function ConvertTo-DateTime {
    param(
        $InputDate,
        [string]$ContextName = "date",
        [switch]$AsString,
        [switch]$ToLocalTime,
        [switch]$FromEpoch
    )
    
    if ($null -eq $InputDate -or ($InputDate -is [string] -and [string]::IsNullOrEmpty($InputDate)) -or ($InputDate -is [ValueType] -and $InputDate -eq 0)) { 
        if ($AsString) { 
            return "" 
        } else { 
            return $null 
        }
    }
    
    try {
        $dateTime = $null
        
        # Handle epoch timestamps
        if ($FromEpoch) {
            $epochNum = $null
            $epoch = $InputDate
            
            # Handle array input for epoch
            if ($epoch -is [array]) {
                $epoch = $epoch | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] -or ($_ -is [string] -and $_ -match '^[0-9]+$') }
                if ($epoch.Count -eq 0) {
                    Write-Log -Message ("Failed to convert epoch time: empty array after filtering") -LogLevel "WARNING"
                    if ($AsString) { 
                        return [string]$InputDate 
                    } else { 
                        return $null 
                    }
                }
                $epoch = $epoch[0]
            }
            
            # Parse the epoch timestamp
            if ($epoch -is [string]) {
                if (-not [double]::TryParse($epoch, [ref]$epochNum)) {
                    Write-Log -Message ("Failed to parse epoch value '{0}' as number" -f $epoch) -LogLevel "WARNING"
                    if ($AsString) { 
                        return [string]$InputDate 
                    } else { 
                        return $null 
                    }
                }
            } elseif ($epoch -is [int] -or $epoch -is [long] -or $epoch -is [double]) {
                $epochNum = [double]$epoch
            } else {
                Write-Log -Message ("Unsupported type for epoch conversion: {0}" -f $epoch.GetType().FullName) -LogLevel "WARNING"
                if ($AsString) { 
                    return [string]$InputDate 
                } else { 
                    return $null 
                }
            }
            
            $dateTime = (Get-Date "1970-01-01 00:00:00Z").AddSeconds($epochNum)
            
            # Epoch timestamps are already in UTC, so we only apply ToLocalTime if requested
            if ($ToLocalTime) {
                $dateTime = $dateTime.ToLocalTime()
            }
        }
        # Handle regular date formats
        else {
            # Handle different input types
            if ($InputDate -is [DateTime]) {
                $dateTime = $InputDate
            } elseif ($InputDate -is [string] -and ![string]::IsNullOrEmpty($InputDate)) {
                $dateTime = [DateTime]::Parse($InputDate)
            } elseif ([DateTime]::TryParse($InputDate, [ref]$null)) {
                $dateTime = [DateTime]$InputDate
            } else {
                Write-Log -Message ("Failed to parse {0}: '{1}' (unsupported type or format)" -f $ContextName, $InputDate) -LogLevel "WARNING"
                if ($AsString) { 
                    return [string]$InputDate 
                } else { 
                    return $null 
                }
            }
            
            # Apply local time conversion if requested
            if ($ToLocalTime -and $null -ne $dateTime) {
                $dateTime = $dateTime.ToLocalTime()
            }
        }
        
        # Return as requested format
        if ($AsString) {
            return $dateTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
        } else {
            return $dateTime
        }
        
    } catch {
        Write-Log -Message ("Failed to process {0} '{1}': {2}" -f $ContextName, $InputDate, $_.Exception.Message) -LogLevel "WARNING"
        if ($AsString) { 
            return [string]$InputDate 
        } else { 
            return $null 
        }
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

# =====================
# Enhanced F5 SSL Profile Collection with Thumbprint Normalization
# =====================
function Get-F5SSLProfileMetadata {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$F5Nodes
    )
    $allProfiles = @()
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
                $sslProfiles = Get-F5SSLProfile -Session $f5Session -ErrorAction Stop
                
                if ($null -eq $sslProfiles) {
                    Write-Log -Message ("No SSL profiles returned for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
                    continue
                }
                
                Write-Log -Message ("Retrieved {0} SSL profiles from {1}" -f $sslProfiles.Count, $nodeObj.DisplayName) -LogLevel "INFO"
                
                foreach ($sslProfile in $sslProfiles) {
                    if ($null -eq $sslProfile -or $sslProfile -is [string] -or -not ($sslProfile -is [PSCustomObject])) { 
                        Write-Log -Message ("Skipping invalid SSL profile object") -LogLevel "DEBUG"
                        continue 
                    }
                    
                    # Add F5 node information to each profile
                    $sslProfile | Add-Member -NotePropertyName "F5Node" -NotePropertyValue $nodeObj.Node -Force
                    $sslProfile | Add-Member -NotePropertyName "F5DisplayName" -NotePropertyValue $nodeObj.DisplayName -Force
                    $sslProfile | Add-Member -NotePropertyName "F5Cluster" -NotePropertyValue $cluster -Force
                    
                    # Normalize certificate paths (remove /Common/ prefix for thumbprint lookup)
                    if ($sslProfile.PSObject.Properties['cert'] -and $sslProfile.cert) {
                        $sslProfile.cert = Format-Thumbprint $sslProfile.cert
                    }
                    if ($sslProfile.PSObject.Properties['chain'] -and $sslProfile.chain -and $sslProfile.chain -ne "none") {
                        $sslProfile.chain = Format-Thumbprint $sslProfile.chain
                    }
                    
                    # Extract cipher group name (remove /Common/ prefix)
                    if ($sslProfile.PSObject.Properties['cipherGroup'] -and $sslProfile.cipherGroup -and $sslProfile.cipherGroup -ne "none") {
                        if ($sslProfile.cipherGroup -match "^/Common/(.+)$") {
                            $sslProfile.cipherGroup = $matches[1]
                        }
                    }
                    
                    $allProfiles += $sslProfile
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
    Write-Log -Message ("SSL profile collection complete. Found {0} total profiles." -f $allProfiles.Count) -LogLevel "INFO"
    return $allProfiles
}

# =====================
# Database Update Function (with normalization)
# =====================
function Update-F5SSLProfileDatabase {
    param (
        [Parameter(Mandatory=$true)]
        [array]$profiles
    )
    if ($null -eq $profiles) {
        Write-Log -Message ("Profiles parameter is null") -LogLevel "ERROR"
        return
    }
    
    try {
        $insertCount = 0
        $skippedCount = 0
        
        if ($profiles.Count -eq 0) {
            Write-Log -Message ("No F5 SSL profiles found to insert into the database") -LogLevel "WARNING"
            return
        }
        
        Write-Log -Message ("Processing {0} F5 SSL profiles for database update" -f $profiles.Count) -LogLevel "INFO"
        
        foreach ($sslProfile in $profiles) {
            if ($null -eq $sslProfile -or $sslProfile -is [string] -or -not ($sslProfile -is [PSCustomObject])) { 
                $skippedCount++
                continue 
            }
            
            # Debug logging to understand the profile structure
            if ($Script:verboseLogging) {
                Write-Log -Message ("DEBUG: Processing SSL profile. Properties: {0}, F5Node: '{1}', Name: '{2}'" -f ($sslProfile.PSObject.Properties.Name -join ', '), $sslProfile.F5Node, $sslProfile.Name) -LogLevel "DEBUG"
            }
            
            # Skip profiles with missing or empty required fields
            if ([string]::IsNullOrEmpty($sslProfile.F5Node)) {
                Write-Log -Message ("SKIP: Profile missing F5Node: {0}" -f ($sslProfile | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                $skippedCount++
                continue
            }
            if ([string]::IsNullOrEmpty($sslProfile.name)) {
                Write-Log -Message ("SKIP: Profile missing Name: {0}" -f ($sslProfile | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                $skippedCount++
                continue
            }
            
            # Use the helper function to safely escape SQL strings
            $escapedF5Node = ConvertTo-SqlString $sslProfile 'F5Node'
            $escapedName = ConvertTo-SqlString $sslProfile 'name'
            $escapedFullPath = ConvertTo-SqlString $sslProfile 'fullPath'
            $escapedPartition = ConvertTo-SqlString $sslProfile 'partition'
            $escapedCert = ConvertTo-SqlString $sslProfile 'cert'
            $escapedChain = ConvertTo-SqlString $sslProfile 'chain'
            $escapedKey = ConvertTo-SqlString $sslProfile 'key'
            $escapedDescription = ConvertTo-SqlString $sslProfile 'description'
            $escapedCipherGroup = ConvertTo-SqlString $sslProfile 'cipherGroup'
            $escapedCiphers = ConvertTo-SqlString $sslProfile 'ciphers'
            $escapedTmOptions = ConvertTo-SqlString $sslProfile 'tmOptions'
            
            # Handle certificate chain information from certKeyChain array
            $certKeyChainInfo = ""
            if ($sslProfile.PSObject.Properties['certKeyChain'] -and $sslProfile.certKeyChain -and $sslProfile.certKeyChain.Count -gt 0) {
                $certKeyChainInfo = ($sslProfile.certKeyChain | ConvertTo-Json -Compress)
            }
            $escapedCertKeyChain = $certKeyChainInfo.Replace("'", "''").Replace("[\x00-\x1F]", '')
            
            # Extract additional SSL configuration details
            $escapedMode = ConvertTo-SqlString $sslProfile 'mode'
            $escapedSecureRenegotiation = ConvertTo-SqlString $sslProfile 'secureRenegotiation'
            $escapedSniDefault = ConvertTo-SqlString $sslProfile 'sniDefault'
            $escapedSniRequire = ConvertTo-SqlString $sslProfile 'sniRequire'
            
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
            
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
        [Partition] = N'$escapedPartition',
        [Cert] = N'$escapedCert',
        [Chain] = N'$escapedChain',
        [SSLKey] = N'$escapedKey',
        [Description] = N'$escapedDescription',
        [CipherGroup] = N'$escapedCipherGroup',
        [Ciphers] = N'$escapedCiphers',
        [TmOptions] = N'$escapedTmOptions',
        [Mode] = N'$escapedMode',
        [SecureRenegotiation] = N'$escapedSecureRenegotiation',
        [SniDefault] = N'$escapedSniDefault',
        [SniRequire] = N'$escapedSniRequire',
        [CertKeyChain] = N'$escapedCertKeyChain',
        [DateAdded] = '$dateAdded'
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [Cert], [Chain], [SSLKey], [Description], [CipherGroup], [Ciphers], [TmOptions], [Mode], [SecureRenegotiation], [SniDefault], [SniRequire], [CertKeyChain], [DateAdded])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', N'$escapedPartition', N'$escapedCert', N'$escapedChain', N'$escapedKey', N'$escapedDescription', N'$escapedCipherGroup', N'$escapedCiphers', N'$escapedTmOptions', N'$escapedMode', N'$escapedSecureRenegotiation', N'$escapedSniDefault', N'$escapedSniRequire', N'$escapedCertKeyChain', '$dateAdded');
"@
            
            if ($Script:verboseLogging) { 
                Write-Log -Message ("DEBUG: SQL Merge Query: {0}" -f $mergeQuery) -LogLevel "DEBUG"
            }
            
            try {
                Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
                $insertCount++
            } catch {
                $sqlError = $_.Exception.Message
                Write-Log -Message ("SQL ERROR: {0} | Query: {1}" -f $sqlError, $mergeQuery) -LogLevel "ERROR"
            }
        }
        Write-Log -Message ("Successfully upserted {0} F5 SSL profiles into the database. Skipped {1} profiles with invalid data." -f $insertCount, $skippedCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update F5 SSL profile database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

# =====================
# F5 REST API Helper Functions (Self-contained)
# =====================
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

function Get-F5SSLProfile {
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
                # Get specific named profiles
                $allProfiles = @()
                foreach ($profileName in $Name) {
                    try {
                        $encodedName = [System.Web.HttpUtility]::UrlEncode($profileName)
                        $uri = "{0}profile/client-ssl/{1}?$select=name,fullPath,cert,key,chain,certExtensionIncludes,certLifespan,chainCA,cipherGroup,crlFile,defaultsFrom,description,forwardProxyBypassDefaultAction,genericAlert,handshakeTimeout,inheritCertkeychain,inheritCiphers,inheritOptions,insertEmptyFragments,modSslMethods,tmOptions,secureRenegotiation,sniDefault,sniRequire&expandSubcollections=true" -f $Session.BaseURL, $encodedName
                        Write-Log -Message ("Requesting specific SSL profile: {0}" -f $uri) -LogLevel "DEBUG"
                        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                        if ($result) {
                            $result | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                            $allProfiles += $result
                        }
                    } catch {
                        Write-Log -Message ("Failed to get SSL profile '{0}': {1}" -f $profileName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                }
                return $allProfiles
            } else {
                # Get all profiles
                $uri = $Session.BaseURL + "profile/client-ssl"
                if ($Partition -and $Partition -ne '') {
                    $uri += "?`$filter=partition+eq+$Partition"
                }
                Write-Log -Message ("Requesting all SSL profiles: {0}" -f $uri) -LogLevel "DEBUG"
                $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                
                if ($result -and $result.items) {
                    Write-Log -Message ("Retrieved {0} SSL profiles from F5" -f $result.items.Count) -LogLevel "DEBUG"
                    foreach ($item in $result.items) {
                        $item | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                    }
                    return $result.items
                } else {
                    Write-Log -Message ("No SSL profiles found or result is empty") -LogLevel "DEBUG"
                    return @()
                }
            }
        } catch {
            $errorMsg = "Error retrieving SSL profile: {0}" -f $_.Exception.Message
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

# =====================
# Main Script Logic
# =====================
try {
    Write-Log -Message ("Starting F5 SSL profile collection script execution") -LogLevel "INFO"
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
    Write-Log -Message ("Starting SSL profile collection from F5 nodes") -LogLevel "INFO"
    
    # Collect SSL profiles from all F5 nodes
    $profiles = Get-F5SSLProfileMetadata -F5Nodes $f5Nodes
    
    if ($null -eq $profiles) {
        Write-Log -Message ("SSL profile collection returned null. Check previous errors.") -LogLevel "ERROR"
    } 
    elseif ($profiles.Count -eq 0) {
        Write-Log -Message ("No SSL profiles found across any F5 nodes. Check for connection issues.") -LogLevel "WARNING"
    }
    else {
        Write-Log -Message ("Collected {0} SSL profiles from F5 nodes" -f $profiles.Count) -LogLevel "INFO"
        Write-Log -Message ("Updating SQL database with collected F5 SSL profiles") -LogLevel "INFO"
        Update-F5SSLProfileDatabase -profiles $profiles
    }
    
    Write-Log -Message ("F5 SSL profile collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 SSL profile collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}
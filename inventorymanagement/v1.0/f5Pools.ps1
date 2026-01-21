# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "f5Pools"
$ScriptName = $Table
$LogTable = "collectionLogs"
$verboseLogging = $true
$SkipMemberDetails = $false
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

function Get-F5Pool {
    [cmdletBinding()]
    param (
        $Session,
        [Parameter(ValueFromPipeline)]
        [string[]]$Name='',
        [string]$Partition = "Common",
        [switch]$ExpandSubcollections
    )
    begin {
        if ($null -eq $Session) {
            throw "No F5 session specified"
        }
    }
    process {
        try {
            if ($Name -and $Name -ne '') {
                $allPools = @()
                foreach ($poolName in $Name) {
                    try {
                        $encodedName = [System.Web.HttpUtility]::UrlEncode($poolName)
                        $uri = "{0}pool/{1}" -f $Session.BaseURL, $encodedName
                        if ($ExpandSubcollections) {
                            $uri += "?expandSubcollections=true"
                        }
                        Write-Log -Message ("Requesting specific pool: {0}" -f $uri) -LogLevel "DEBUG"
                        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                        if ($result) {
                            $result | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                            $allPools += $result
                        }
                    } catch {
                        Write-Log -Message ("Failed to get pool '{0}': {1}" -f $poolName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                }
                return $allPools
            } else {
                $uri = $Session.BaseURL + "pool"
                $queryParams = @()
                
                if ($Partition -and $Partition -ne '') {
                    $queryParams += "`$filter=partition+eq+$Partition"
                }
                
                if ($ExpandSubcollections) {
                    $queryParams += "expandSubcollections=true"
                }
                
                if ($queryParams.Count -gt 0) {
                    $uri += "?" + ($queryParams -join "&")
                }
                
                Write-Log -Message ("Requesting all pools with bulk optimization: {0}" -f $uri) -LogLevel "INFO"
                $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                if ($result -and $result.items) {
                    Write-Log -Message ("Retrieved {0} pools from F5 using bulk API" -f $result.items.Count) -LogLevel "INFO"
                    foreach ($item in $result.items) {
                        $item | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                    }
                    return $result.items
                } else {
                    Write-Log -Message ("No pools found or result is empty") -LogLevel "WARNING"
                    return @()
                }
            }
        } catch {
            $errorMsg = "Error retrieving pool: {0}" -f $_.Exception.Message
            Write-Log -Message $errorMsg -LogLevel "ERROR"
            return $null
        }
    }
}

function Get-F5PoolMembers {
    [cmdletBinding()]
    param (
        $Session,
        [Parameter(Mandatory=$true)]
        [string]$PoolName,
        [string]$Partition = "Common"
    )
    
    if ($null -eq $Session) {
        Write-Log -Message ("No F5 session specified for pool members") -LogLevel "WARNING"
        return @()
    }
    
    try {
        # URL encode the pool name for the API call
        $encodedPoolName = [System.Web.HttpUtility]::UrlEncode($PoolName)
        $uri = "{0}pool/{1}/members" -f $Session.BaseURL, $encodedPoolName
        
        Write-Log -Message ("Requesting pool members for '{0}': {1}" -f $PoolName, $uri) -LogLevel "DEBUG"
        
        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
        
        if ($result -and $result.items) {
            Write-Log -Message ("Retrieved {0} members for pool '{1}'" -f $result.items.Count, $PoolName) -LogLevel "INFO"
            
            # Add pool context to each member
            foreach ($member in $result.items) {
                $member | Add-Member -MemberType NoteProperty -Name "PoolName" -Value $PoolName -Force
                $member | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
            }
            
            return $result.items
        } else {
            Write-Log -Message ("No members found for pool '{0}'" -f $PoolName) -LogLevel "WARNING"
            return @()
        }
    } catch {
        $errorMsg = "Error retrieving pool members for '{0}': {1}" -f $PoolName, $_.Exception.Message
        Write-Log -Message $errorMsg -LogLevel "WARNING"
        return @()
    }
}

function ConvertFrom-F5EmbeddedMembers {
    [cmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        $Pool
    )
    
    # Debug: Log all pool properties to understand the structure
    if ($Script:verboseLogging) {
        $poolProps = $Pool.PSObject.Properties.Name -join ', '
        Write-Log -Message ("Pool '{0}' has properties: {1}" -f $Pool.name, $poolProps) -LogLevel "DEBUG"
        
        # Check various possible member structures
        if ($Pool.PSObject.Properties['members']) {
            Write-Log -Message ("Pool '{0}' has 'members' property. Type: {1}" -f $Pool.name, $Pool.members.GetType().FullName) -LogLevel "DEBUG"
            if ($Pool.members -is [PSCustomObject] -and $Pool.members.PSObject.Properties['items']) {
                Write-Log -Message ("Pool '{0}' members.items exists with {1} items" -f $Pool.name, $Pool.members.items.Count) -LogLevel "DEBUG"
            } elseif ($Pool.members -is [Array]) {
                Write-Log -Message ("Pool '{0}' members is direct array with {1} items" -f $Pool.name, $Pool.members.Count) -LogLevel "DEBUG"
            } else {
                Write-Log -Message ("Pool '{0}' members structure: {1}" -f $Pool.name, ($Pool.members | ConvertTo-Json -Depth 2 -Compress)) -LogLevel "DEBUG"
            }
        }
        
        if ($Pool.PSObject.Properties['membersReference']) {
            Write-Log -Message ("Pool '{0}' has membersReference with embedded items: {1}" -f $Pool.name, ($Pool.membersReference.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
            if ($Pool.membersReference.PSObject.Properties['items'] -and $Pool.membersReference.items) {
                Write-Log -Message ("Pool '{0}' membersReference.items exists with {1} items" -f $Pool.name, $Pool.membersReference.items.Count) -LogLevel "DEBUG"
            }
        }
    }
    
    # Method 1: Check if pool has embedded members data as members.items (standard structure)
    if ($Pool.PSObject.Properties['members'] -and $Pool.members -and $Pool.members.PSObject.Properties['items'] -and $Pool.members.items) {
        Write-Log -Message ("Processing embedded members (members.items) for pool '{0}'" -f $Pool.name) -LogLevel "DEBUG"
        $poolMembers = $Pool.members.items
        $dataSource = "embedded-bulk-api-members"
    }
    # Method 2: Check if members is directly an array (alternative structure)
    elseif ($Pool.PSObject.Properties['members'] -and $Pool.members -and $Pool.members -is [Array] -and $Pool.members.Count -gt 0) {
        Write-Log -Message ("Processing embedded members (direct array) for pool '{0}'" -f $Pool.name) -LogLevel "DEBUG"
        $poolMembers = $Pool.members
        $dataSource = "embedded-bulk-api-array"
    }
    # Method 3: Check if membersReference has embedded items (F5 17.x format with expandSubcollections)
    elseif ($Pool.PSObject.Properties['membersReference'] -and $Pool.membersReference -and $Pool.membersReference.PSObject.Properties['items'] -and $Pool.membersReference.items -and $Pool.membersReference.items.Count -gt 0) {
        Write-Log -Message ("Processing embedded members (membersReference.items) for pool '{0}'" -f $Pool.name) -LogLevel "DEBUG"
        $poolMembers = $Pool.membersReference.items
        $dataSource = "embedded-bulk-api-membersref"
    }
    # Method 4: Check if members exist but empty
    elseif ($Pool.PSObject.Properties['members'] -and $Pool.members) {
        Write-Log -Message ("Pool '{0}' has members property but no member data (empty pool)" -f $Pool.name) -LogLevel "DEBUG"
        return @{
            memberCount = 0
            members = @()
            source = "embedded-empty"
        }
    }
    # Method 5: Check if membersReference exists but has no embedded items (will need fallback)
    elseif ($Pool.PSObject.Properties['membersReference'] -and $Pool.membersReference -and $Pool.membersReference.PSObject.Properties['link']) {
        Write-Log -Message ("Pool '{0}' has membersReference.link but no embedded items - needs fallback API call" -f $Pool.name) -LogLevel "DEBUG"
        return $null
    }
    else {
        # No embedded members found - will fall back to individual API calls
        Write-Log -Message ("No embedded members found for pool '{0}' - will use fallback API" -f $Pool.name) -LogLevel "DEBUG"
        return $null
    }
    
    # Process the found embedded members
    if ($poolMembers -and $poolMembers.Count -gt 0) {
        Write-Log -Message ("Found {0} embedded members for pool '{1}' using {2}" -f $poolMembers.Count, $Pool.name, $dataSource) -LogLevel "INFO"
        
        # Create enhanced members data with detailed information
        $enhancedMembersData = @{
            memberCount = $poolMembers.Count
            members = @()
            source = $dataSource
        }
        
        foreach ($member in $poolMembers) {
            $memberInfo = @{
                name = if ($member.name) { $member.name } else { "" }
                fullPath = if ($member.fullPath) { $member.fullPath } else { "" }
                address = if ($member.address) { $member.address } else { "" }
                port = if ($member.port) { $member.port } else { 0 }
                session = if ($member.session) { $member.session } else { "" }
                state = if ($member.state) { $member.state } else { "" }
                enabled = if ($member.PSObject.Properties['enabled'] -and $null -ne $member.enabled) { $member.enabled } else { $false }
                ratio = if ($member.ratio) { $member.ratio } else { 1 }
                priority = if ($member.priorityGroup) { $member.priorityGroup } elseif ($member.priority) { $member.priority } else { 0 }
                connectionLimit = if ($member.connectionLimit) { $member.connectionLimit } else { 0 }
                rateLimit = if ($member.rateLimit) { $member.rateLimit } else { "" }
                monitor = if ($member.monitor) { $member.monitor } else { "" }
                description = if ($member.description) { $member.description } else { "" }
            }
            $enhancedMembersData.members += $memberInfo
        }
        
        return $enhancedMembersData
    }
    
    # No embedded members found
    return $null
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
# POOL COLLECTION AND PROCESSING SECTION
# =====================================================

function Test-ValidF5PoolObject {
    param([object]$obj)
    
    if ($null -eq $obj) {
        Write-Log -Message ("Pool object is null") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not ($obj -is [PSCustomObject])) {
        Write-Log -Message ("Pool object is not PSCustomObject: {0}" -f $obj.GetType().FullName) -LogLevel "DEBUG"
        return $false
    }
    
    if ($obj.PSObject.Properties.Count -eq 0) {
        Write-Log -Message ("Pool object has no properties") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['name']) {
        Write-Log -Message ("Pool object missing name property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "WARNING"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.name)) {
        Write-Log -Message ("Pool name is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['F5Node']) {
        Write-Log -Message ("Pool object missing F5Node property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "WARNING"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.F5Node)) {
        Write-Log -Message ("Pool F5Node is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    return $true
}

# =====================
# Pool Collection
# =====================
function Get-F5PoolMetadata {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$F5Nodes
    )
    $allPools = @()
    foreach ($cluster in $F5Nodes.Keys) {
        foreach ($nodeObj in $F5Nodes[$cluster]) {
            $connectName = Get-BestF5NodeAddress -NodeObj $nodeObj
            if ($null -eq $connectName) {
                Write-Log -Message ("No valid connection address found for node: {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Processing F5 node: {0} (using address: {1})" -f $nodeObj.DisplayName, $connectName) -LogLevel "INFO"
            
            # Add a delay between node connections to reduce load on F5 devices
            Start-Sleep -Seconds 1
            
            try {
                # Use longer token lifespan for bulk operations
                $f5Session = New-F5Session -LTMName $connectName -Credential $Credential -ErrorAction Stop -PassThru -TokenLifespan 3600
                if ($null -eq $f5Session) {
                    Write-Log -Message ("Failed to create session for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    continue
                }
                
                # Use bulk API with expandSubcollections to get pools and members in one call
                Write-Log -Message ("Fetching pools with embedded member data for {0}" -f $nodeObj.DisplayName) -LogLevel "INFO"
                $pools = Get-F5Pool -Session $f5Session -ExpandSubcollections -ErrorAction Stop
                
                if ($null -eq $pools) {
                    Write-Log -Message ("No pools returned for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
                    continue
                }
                Write-Log -Message ("Retrieved {0} pools with bulk API from {1}" -f $pools.Count, $nodeObj.DisplayName) -LogLevel "INFO"
                
                # Log a sample for debugging (only in DEBUG mode)
                if ($pools.Count -gt 0 -and $Script:verboseLogging) {
                    $samplePool = $pools[0]
                    $rawJson = $samplePool | ConvertTo-Json -Depth 3  # Reduced depth for performance
                    Write-Log -Message ("Sample pool structure from {0}: {1}" -f $nodeObj.DisplayName, $rawJson) -LogLevel "DEBUG"
                    
                    # Quick check for embedded member data
                    $poolsWithEmbeddedMembers = 0
                    $poolsWithMembersRef = 0
                    $poolsEmpty = 0
                    foreach ($checkPool in $pools) {
                        if (($checkPool.PSObject.Properties['members'] -and $checkPool.members -and $checkPool.members.items) -or
                            ($checkPool.PSObject.Properties['membersReference'] -and $checkPool.membersReference -and $checkPool.membersReference.items)) {
                            $poolsWithEmbeddedMembers++
                        } elseif ($checkPool.PSObject.Properties['membersReference'] -and $checkPool.membersReference -and $checkPool.membersReference.link) {
                            $poolsWithMembersRef++
                        } else {
                            $poolsEmpty++
                        }
                    }
                    Write-Log -Message ("Bulk API results from {0}: {1} pools with embedded members, {2} with membersReference only, {3} empty" -f $nodeObj.DisplayName, $poolsWithEmbeddedMembers, $poolsWithMembersRef, $poolsEmpty) -LogLevel "INFO"
                }
                
                $processedCount = 0
                foreach ($pool in $pools) {
                    if ($null -eq $pool -or $pool -is [string] -or -not ($pool -is [PSCustomObject])) {
                        Write-Log -Message ("Skipping invalid pool object") -LogLevel "DEBUG"
                        continue
                    }
                    
                    # Add F5Node information
                    $pool | Add-Member -NotePropertyName "F5Node" -NotePropertyValue $nodeObj.Node -Force
                    
                    # Check if member details collection is enabled
                    if ($SkipMemberDetails) {
                        # Skip member detail collection for faster execution
                        $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue @{ memberCount = 0; members = @(); skipped = $true } -Force
                        Write-Log -Message ("Skipped member details for pool '{0}' (SkipMemberDetails enabled)" -f $pool.name) -LogLevel "DEBUG"
                    } else {
                        # Try to process embedded member data first (from bulk API)
                        $enhancedMembersData = ConvertFrom-F5EmbeddedMembers -Pool $pool
                        
                        if ($enhancedMembersData) {
                            # Successfully processed embedded member data
                            $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue $enhancedMembersData -Force
                            $dataSource = if ($enhancedMembersData.source) { $enhancedMembersData.source } else { "embedded" }
                            Write-Log -Message ("Processed {0} members for pool '{1}' using {2}" -f $enhancedMembersData.memberCount, $pool.name, $dataSource) -LogLevel "INFO"
                        }
                        elseif ($pool.PSObject.Properties['membersReference'] -and $pool.membersReference -and $pool.membersReference.link) {
                            # Fallback to individual API call only if embedded data not available
                            Write-Log -Message ("No embedded data for pool '{0}' - fetching individual members via API" -f $pool.name) -LogLevel "WARNING"
                            
                            try {
                                # Reduced delay since this should be rare with bulk API
                                Start-Sleep -Milliseconds 100
                                
                                $poolMembers = Get-F5PoolMembers -Session $f5Session -PoolName $pool.name
                                
                                if ($poolMembers -and $poolMembers.Count -gt 0) {
                                    # Create enhanced members data with detailed information
                                    $enhancedMembersData = @{
                                        memberCount = $poolMembers.Count
                                        members = @()
                                        source = "individual-api-fallback"
                                    }
                                    
                                    foreach ($member in $poolMembers) {
                                        $memberInfo = @{
                                            name = if ($member.name) { $member.name } else { "" }
                                            fullPath = if ($member.fullPath) { $member.fullPath } else { "" }
                                            address = if ($member.address) { $member.address } else { "" }
                                            port = if ($member.port) { $member.port } else { 0 }
                                            session = if ($member.session) { $member.session } else { "" }
                                            state = if ($member.state) { $member.state } else { "" }
                                            enabled = if ($member.PSObject.Properties['enabled'] -and $null -ne $member.enabled) { $member.enabled } else { $false }
                                            ratio = if ($member.ratio) { $member.ratio } else { 1 }
                                            priority = if ($member.priority) { $member.priority } else { 0 }
                                            connectionLimit = if ($member.connectionLimit) { $member.connectionLimit } else { 0 }
                                            rateLimit = if ($member.rateLimit) { $member.rateLimit } else { "" }
                                            monitor = if ($member.monitor) { $member.monitor } else { "" }
                                            description = if ($member.description) { $member.description } else { "" }
                                        }
                                        $enhancedMembersData.members += $memberInfo
                                    }
                                    
                                    # Replace the simple membersReference with detailed data
                                    $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue $enhancedMembersData -Force
                                    
                                    Write-Log -Message ("Enhanced pool '{0}' with {1} individual API members (fallback)" -f $pool.name, $enhancedMembersData.memberCount) -LogLevel "INFO"
                                } else {
                                    Write-Log -Message ("No detailed members found for pool '{0}' (fallback failed)" -f $pool.name) -LogLevel "WARNING"
                                    $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue @{ memberCount = 0; members = @(); source = "empty-fallback" } -Force
                                }
                            }
                            catch {
                                Write-Log -Message ("Failed to fetch members for pool '{0}': {1}. Using empty structure." -f $pool.name, $_.Exception.Message) -LogLevel "WARNING"
                                $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue @{ memberCount = 0; members = @(); source = "error-fallback" } -Force
                            }
                        } else {
                            # No members reference found
                            Write-Log -Message ("Pool '{0}' has no members reference - likely empty pool" -f $pool.name) -LogLevel "INFO"
                            $pool | Add-Member -NotePropertyName "DetailedMembers" -NotePropertyValue @{ memberCount = 0; members = @(); source = "no-members-ref" } -Force
                        }
                    }
                    
                    # Validate the pool object before adding to collection
                    if (Test-ValidF5PoolObject $pool) {
                        $allPools += $pool
                        $processedCount++
                    } else {
                        Write-Log -Message ("Skipping invalid pool: {0}" -f ($pool | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                    }
                }
                
                Write-Log -Message ("Successfully processed {0} pools from {1}" -f $processedCount, $nodeObj.DisplayName) -LogLevel "INFO"
                Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
                
            } catch {
                $errMsg = $_.Exception.Message
                Write-Log -Message ("Error processing node {0}: {1}" -f $nodeObj.DisplayName, $errMsg) -LogLevel "ERROR"
                if ($f5Session) {
                    try { Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }
    Write-Log -Message ("Pool collection complete. Found {0} total pools." -f $allPools.Count) -LogLevel "INFO"
    return $allPools
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

function Update-F5PoolDatabase {
    param (
        [Parameter(Mandatory=$true)]
        [array]$pools
    )
    if ($null -eq $pools) {
        Write-Log -Message ("Pools parameter is null") -LogLevel "ERROR"
        return
    }
    
    # ===============================================================================
    # F5 Pool API Response to Database Field Mapping (Actual Database Schema)
    # ===============================================================================
    # F5 API Field          → Database Column       → Description
    # ─────────────────────────────────────────────────────────────────────────────
    # name                 → Name                  → Pool name (e.g., "exchange-iapp_587")
    # partition            → Partition             → F5 partition (usually "Common")
    # fullPath             → FullPath              → Full path with partition ("/Common/pool_name")
    # kind                 → F5ObjectType          → API object type ("tm:ltm:pool:poolstate")
    # generation           → Generation            → F5 version/generation number (numeric)
    # selfLink             → F5ApiUrl              → REST API self-reference URL
    # description          → Description           → Pool description/comment (optional field)
    # loadBalancingMode    → LoadBalancingMode     → LB algorithm (round-robin, least-connections, etc.)
    # monitor              → HealthMonitors        → Health monitors (string/JSON - e.g., "/Common/tcp")
    # allowNat             → AllowNat              → NAT configuration (yes/no)
    # allowSnat            → AllowSnat             → SNAT configuration (yes/no)
    # ipTosToClient        → IpTosToClient         → IP TOS to client (pass-through, etc.)
    # ipTosToServer        → IpTosToServer         → IP TOS to server (pass-through, etc.)
    # linkQosToClient      → LinkQosToClient       → Link QoS to client (pass-through, etc.)
    # linkQosToServer      → LinkQosToServer       → Link QoS to server (pass-through, etc.)
    # minActiveMembers     → MinActiveMembers      → Minimum active members (numeric)
    # minUpMembers         → MinUpMembers          → Minimum up members (numeric)
    # minUpMembersAction   → MinUpMembersAction    → Action when min up members not met (failover, etc.)
    # minUpMembersChecking → MinUpMembersChecking  → Min up members checking (enabled/disabled)
    # queueDepthLimit      → QueueDepthLimit       → Queue depth limit (numeric)
    # queueOnConnectionLimit → QueueOnConnectionLimit → Queue on connection limit (enabled/disabled)
    # queueTimeLimit       → QueueTimeLimit        → Queue time limit (numeric)
    # reselectTries        → ReselectTries         → Reselect tries (numeric)
    # serviceDownAction    → ServiceDownAction     → Service down action (none, reset, etc.)
    # slowRampTime         → SlowRampTime          → Slow ramp time (numeric)
    # membersReference     → MembersData           → Pool members information (enhanced JSON)
    #   └─ (enhanced)      → MembersData.memberCount → Number of pool members
    #   └─ (enhanced)      → MembersData.members[]   → Array of detailed member objects:
    #      ├─ name         →   Member name/identifier
    #      ├─ fullPath     →   Full path with partition  
    #      ├─ address      →   IP address of member
    #      ├─ port         →   Port number
    #      ├─ session      →   Session state (enabled/disabled)
    #      ├─ state        →   Operational state (up/down)
    #      ├─ enabled      →   Administrative state (true/false)
    #      ├─ ratio        →   Load balancing ratio/weight
    #      ├─ priority     →   Priority group
    #      ├─ connectionLimit → Connection limit
    #      ├─ rateLimit    →   Rate limiting configuration
    #      ├─ monitor      →   Health monitor assignment
    #      └─ description  →   Member description/comment
    # (script-added)       → F5Node                → Source F5 node identifier
    # (auto-generated)     → DateAdded             → Record creation timestamp (DEFAULT GETDATE())
    # (auto-updated)       → LastUpdated           → Record update timestamp (DEFAULT GETDATE())
    # ===============================================================================
    
    try {
        $insertCount = 0
        $skippedCount = 0
        if ($pools.Count -eq 0) {
            Write-Log -Message ("No F5 pools found to insert into the database") -LogLevel "WARNING"
            return
        }
        Write-Log -Message ("Processing {0} F5 pools for database update" -f $pools.Count) -LogLevel "INFO"
        foreach ($pool in $pools) {
            if (-not (Test-ValidF5PoolObject $pool)) {
                Write-Log -Message ("Invalid pool object: {0}" -f ($pool | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                $skippedCount++
                continue
            }
            
            # Basic pool information
            $escapedF5Node = ConvertTo-SqlString $pool 'F5Node'
            $escapedName = ConvertTo-SqlString $pool 'name'
            $escapedFullPath = ConvertTo-SqlString $pool 'fullPath'
            $escapedPartition = ConvertTo-SqlString $pool 'partition'
            $escapedKind = ConvertTo-SqlString $pool 'kind'
            $escapedSelfLink = ConvertTo-SqlString $pool 'selfLink'
            $escapedDescription = ConvertTo-SqlString $pool 'description'
            $escapedLoadBalancingMode = ConvertTo-SqlString $pool 'loadBalancingMode'
            $escapedAllowNat = ConvertTo-SqlString $pool 'allowNat'
            $escapedAllowSnat = ConvertTo-SqlString $pool 'allowSnat'
            $escapedServiceDownAction = ConvertTo-SqlString $pool 'serviceDownAction'
            $escapedMinUpMembersAction = ConvertTo-SqlString $pool 'minUpMembersAction'
            
            # Handle QoS and TOS fields
            $escapedIpTosToClient = ConvertTo-SqlString $pool 'ipTosToClient'
            $escapedIpTosToServer = ConvertTo-SqlString $pool 'ipTosToServer'
            $escapedLinkQosToClient = ConvertTo-SqlString $pool 'linkQosToClient'
            $escapedLinkQosToServer = ConvertTo-SqlString $pool 'linkQosToServer'
            
            # Handle generation (numeric field)
            $generation = 0
            if ($pool.PSObject.Properties['generation'] -and $pool.generation) {
                try {
                    $generation = [int]$pool.generation
                } catch {
                    $generation = 0
                }
            }
            
            # Handle numeric fields with null handling
            $minActiveMembers = 'NULL'
            if ($pool.PSObject.Properties['minActiveMembers'] -and $pool.minActiveMembers) {
                try {
                    $minActiveMembers = [int]$pool.minActiveMembers
                } catch {
                    $minActiveMembers = 'NULL'
                }
            }
            
            $minUpMembers = 'NULL'
            if ($pool.PSObject.Properties['minUpMembers'] -and $pool.minUpMembers) {
                try {
                    $minUpMembers = [int]$pool.minUpMembers
                } catch {
                    $minUpMembers = 'NULL'
                }
            }
            
            $queueDepthLimit = 'NULL'
            if ($pool.PSObject.Properties['queueDepthLimit'] -and $pool.queueDepthLimit) {
                try {
                    $queueDepthLimit = [int]$pool.queueDepthLimit
                } catch {
                    $queueDepthLimit = 'NULL'
                }
            }
            
            $queueTimeLimit = 'NULL'
            if ($pool.PSObject.Properties['queueTimeLimit'] -and $pool.queueTimeLimit) {
                try {
                    $queueTimeLimit = [int]$pool.queueTimeLimit
                } catch {
                    $queueTimeLimit = 'NULL'
                }
            }
            
            $reselectTries = 'NULL'
            if ($pool.PSObject.Properties['reselectTries'] -and $pool.reselectTries) {
                try {
                    $reselectTries = [int]$pool.reselectTries
                } catch {
                    $reselectTries = 'NULL'
                }
            }
            
            $slowRampTime = 'NULL'
            if ($pool.PSObject.Properties['slowRampTime'] -and $pool.slowRampTime) {
                try {
                    $slowRampTime = [int]$pool.slowRampTime
                } catch {
                    $slowRampTime = 'NULL'
                }
            }
            
            # Handle boolean fields
            $minUpMembersChecking = 'NULL'
            if ($pool.PSObject.Properties['minUpMembersChecking']) {
                $minUpMembersChecking = if ($pool.minUpMembersChecking -eq 'enabled') { 1 } else { 0 }
            }
            
            $queueOnConnectionLimit = 'NULL'
            if ($pool.PSObject.Properties['queueOnConnectionLimit']) {
                $queueOnConnectionLimit = if ($pool.queueOnConnectionLimit -eq 'enabled') { 1 } else { 0 }
            }
            
            # Handle complex objects as JSON
            $healthMonitors = ""
            if ($pool.PSObject.Properties['monitor'] -and $pool.monitor) {
                if ($pool.monitor -is [string]) {
                    # Simple string monitor (e.g., "/Common/tcp")
                    $healthMonitors = $pool.monitor.Replace("'", "''")
                } else {
                    # Complex monitor object
                    $healthMonitors = ($pool.monitor | ConvertTo-Json -Compress).Replace("'", "''")
                }
            }
            
            $membersData = ""
            if ($pool.PSObject.Properties['DetailedMembers'] -and $pool.DetailedMembers) {
                # Use the enhanced detailed members data
                $membersData = ($pool.DetailedMembers | ConvertTo-Json -Compress -Depth 10).Replace("'", "''")
                Write-Log -Message ("Pool '{0}' has {1} detailed members, JSON size: {2} chars" -f $pool.name, $pool.DetailedMembers.memberCount, $membersData.Length) -LogLevel "INFO"
            } else {
                # Always store empty members structure instead of falling back to old membersReference format
                $emptyMembersStructure = @{
                    memberCount = 0
                    members = @()
                    fallbackNote = "No detailed member data available"
                }
                $membersData = ($emptyMembersStructure | ConvertTo-Json -Compress).Replace("'", "''")
                Write-Log -Message ("Pool '{0}' stored with empty members structure (no detailed data available)" -f $pool.name) -LogLevel "WARNING"
            }
            
            # Log key field values for debugging
            Write-Log -Message ("Processing pool: F5Node='{0}', Name='{1}', FullPath='{2}', LB Mode='{3}'" -f $escapedF5Node, $escapedName, $escapedFullPath, $escapedLoadBalancingMode) -LogLevel "DEBUG"
            Write-Log -Message ("Field values - Partition: '{0}', F5ObjectType: '{1}', Generation: {2}, Description: '{3}'" -f $escapedPartition, $escapedKind, $generation, $escapedDescription) -LogLevel "DEBUG"
            
            # Create the MERGE query for the f5Pools table (using actual database schema)
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
        [F5ObjectType] = NULLIF(N'$escapedKind', ''),
        [Generation] = $generation,
        [F5ApiUrl] = NULLIF(N'$escapedSelfLink', ''),
        [Description] = NULLIF(N'$escapedDescription', ''),
        [LoadBalancingMode] = NULLIF(N'$escapedLoadBalancingMode', ''),
        [HealthMonitors] = NULLIF(N'$healthMonitors', ''),
        [AllowNat] = NULLIF(N'$escapedAllowNat', ''),
        [AllowSnat] = NULLIF(N'$escapedAllowSnat', ''),
        [IpTosToClient] = NULLIF(N'$escapedIpTosToClient', ''),
        [IpTosToServer] = NULLIF(N'$escapedIpTosToServer', ''),
        [LinkQosToClient] = NULLIF(N'$escapedLinkQosToClient', ''),
        [LinkQosToServer] = NULLIF(N'$escapedLinkQosToServer', ''),
        [MinActiveMembers] = $minActiveMembers,
        [MinUpMembers] = $minUpMembers,
        [MinUpMembersAction] = NULLIF(N'$escapedMinUpMembersAction', ''),
        [MinUpMembersChecking] = $minUpMembersChecking,
        [QueueDepthLimit] = $queueDepthLimit,
        [QueueOnConnectionLimit] = $queueOnConnectionLimit,
        [QueueTimeLimit] = $queueTimeLimit,
        [ReselectTries] = $reselectTries,
        [ServiceDownAction] = NULLIF(N'$escapedServiceDownAction', ''),
        [SlowRampTime] = $slowRampTime,
        [MembersData] = NULLIF(N'$membersData', ''),
        [LastUpdated] = GETDATE()
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [F5ObjectType], [Generation], [F5ApiUrl], [Description], [LoadBalancingMode], [HealthMonitors], [AllowNat], [AllowSnat], [IpTosToClient], [IpTosToServer], [LinkQosToClient], [LinkQosToServer], [MinActiveMembers], [MinUpMembers], [MinUpMembersAction], [MinUpMembersChecking], [QueueDepthLimit], [QueueOnConnectionLimit], [QueueTimeLimit], [ReselectTries], [ServiceDownAction], [SlowRampTime], [MembersData], [DateAdded])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', NULLIF(N'$escapedPartition', ''), NULLIF(N'$escapedKind', ''), $generation, NULLIF(N'$escapedSelfLink', ''), NULLIF(N'$escapedDescription', ''), NULLIF(N'$escapedLoadBalancingMode', ''), NULLIF(N'$healthMonitors', ''), NULLIF(N'$escapedAllowNat', ''), NULLIF(N'$escapedAllowSnat', ''), NULLIF(N'$escapedIpTosToClient', ''), NULLIF(N'$escapedIpTosToServer', ''), NULLIF(N'$escapedLinkQosToClient', ''), NULLIF(N'$escapedLinkQosToServer', ''), $minActiveMembers, $minUpMembers, NULLIF(N'$escapedMinUpMembersAction', ''), $minUpMembersChecking, $queueDepthLimit, $queueOnConnectionLimit, $queueTimeLimit, $reselectTries, NULLIF(N'$escapedServiceDownAction', ''), $slowRampTime, NULLIF(N'$membersData', ''), GETDATE());
"@
            try {
                Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery -ErrorAction Stop
                $insertCount++
                Write-Log -Message ("Successfully processed pool: {0} on node {1}" -f $pool.name, $pool.F5Node) -LogLevel "INFO"
            } catch {
                $sqlError = $_.Exception.Message
                Write-Log -Message ("SQL ERROR: {0} | Query: {1}" -f $sqlError, $mergeQuery) -LogLevel "ERROR"
            }
        }
        Write-Log -Message ("Successfully upserted {0} F5 pools into the database. Skipped {1} with invalid data." -f $insertCount, $skippedCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update F5 pool database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

# =====================================================
# MAIN SCRIPT EXECUTION SECTION
# =====================================================

try {
    Write-Log -Message ("Starting F5 pool collection script execution") -LogLevel "INFO"
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
    Write-Log -Message ("Starting pool collection from F5 nodes") -LogLevel "INFO"
    $pools = Get-F5PoolMetadata -F5Nodes $f5Nodes
    if ($null -eq $pools) {
        Write-Log -Message ("Pool collection returned null. Check previous errors.") -LogLevel "ERROR"
    } elseif ($pools.Count -eq 0) {
        Write-Log -Message ("No pools found across any F5 nodes. Check for connection issues.") -LogLevel "WARNING"
    } else {
        Write-Log -Message ("Collected {0} pools from F5 nodes" -f $pools.Count) -LogLevel "INFO"

        # Update the database with the collected pools
        Update-F5PoolDatabase -pools $pools
    }
    Write-Log -Message ("F5 pool collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 pool collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}

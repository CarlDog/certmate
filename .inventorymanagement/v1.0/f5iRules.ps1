# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "f5iRules"
$ScriptName = $Table
$LogTable = "collectionLogs"
$verboseLogging = $true
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

function Get-F5iRule {
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
                $allRules = @()
                foreach ($ruleName in $Name) {
                    try {
                        $encodedName = [System.Web.HttpUtility]::UrlEncode($ruleName)
                        $uri = "{0}rule/{1}" -f $Session.BaseURL, $encodedName
                        Write-Log -Message ("Requesting specific iRule: {0}" -f $uri) -LogLevel "DEBUG"
                        $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                        if ($result) {
                            $result | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                            $allRules += $result
                        }
                    } catch {
                        Write-Log -Message ("Failed to get iRule '{0}': {1}" -f $ruleName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                }
                return $allRules
            } else {
                $uri = $Session.BaseURL + "rule"
                if ($Partition -and $Partition -ne '') {
                    $uri += "?`$filter=partition+eq+$Partition"
                }
                Write-Log -Message ("Requesting all iRules: {0}" -f $uri) -LogLevel "DEBUG"
                $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                if ($result -and $result.items) {
                    Write-Log -Message ("Retrieved {0} iRules from F5" -f $result.items.Count) -LogLevel "DEBUG"
                    foreach ($item in $result.items) {
                        $item | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session -Force
                    }
                    return $result.items
                } else {
                    Write-Log -Message ("No iRules found or result is empty") -LogLevel "DEBUG"
                    return @()
                }
            }
        } catch {
            $errorMsg = "Error retrieving iRule: {0}" -f $_.Exception.Message
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
# IRULE COLLECTION AND PROCESSING SECTION
# =====================================================

function Test-ValidF5iRuleObject {
    param([object]$obj)
    
    if ($null -eq $obj) {
        Write-Log -Message ("iRule object is null") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not ($obj -is [PSCustomObject])) {
        Write-Log -Message ("iRule object is not PSCustomObject: {0}" -f $obj.GetType().FullName) -LogLevel "DEBUG"
        return $false
    }
    
    if ($obj.PSObject.Properties.Count -eq 0) {
        Write-Log -Message ("iRule object has no properties") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['name']) {
        Write-Log -Message ("iRule object missing name property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.name)) {
        Write-Log -Message ("iRule name is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['F5Node']) {
        Write-Log -Message ("iRule object missing F5Node property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.F5Node)) {
        Write-Log -Message ("iRule F5Node is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    return $true
}

# =====================
# iRule Collection
# =====================
function Get-F5iRuleMetadata {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$F5Nodes
    )
    $allRules = @()
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
                $iRules = Get-F5iRule -Session $f5Session -ErrorAction Stop
                if ($null -eq $iRules) {
                    Write-Log -Message ("No iRules returned for {0}" -f $nodeObj.DisplayName) -LogLevel "WARNING"
                    Disconnect-F5LTM -Session $f5Session -ErrorAction SilentlyContinue
                    continue
                }
                Write-Log -Message ("Retrieved {0} iRules from {1}" -f $iRules.Count, $nodeObj.DisplayName) -LogLevel "INFO"
                
                if ($iRules.Count -gt 0) {
                    $sampleRule = $iRules[0]
                    $rawJson = $sampleRule | ConvertTo-Json -Depth 5
                    Write-Log -Message ("RAW JSON from {0}: {1}" -f $nodeObj.DisplayName, $rawJson) -LogLevel "DEBUG"
                }
                foreach ($rule in $iRules) {
                    if ($null -eq $rule -or $rule -is [string] -or -not ($rule -is [PSCustomObject])) {
                        Write-Log -Message ("Skipping invalid iRule object") -LogLevel "DEBUG"
                        continue
                    }
                    
                    # Log raw JSON for each individual iRule for debugging
                    $ruleJson = $rule | ConvertTo-Json -Depth 5 -Compress
                    Write-Log -Message ("Individual iRule JSON: {0}" -f $ruleJson) -LogLevel "DEBUG"
                    
                    $rule | Add-Member -NotePropertyName "F5Node" -NotePropertyValue $nodeObj.Node -Force
                    
                    # Validate the iRule object before adding to collection
                    if (Test-ValidF5iRuleObject $rule) {
                        $allRules += $rule
                    } else {
                        Write-Log -Message ("Skipping invalid iRule: {0}" -f ($rule | ConvertTo-Json -Compress)) -LogLevel "WARNING"
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
    Write-Log -Message ("iRule collection complete. Found {0} total iRules." -f $allRules.Count) -LogLevel "INFO"
    return $allRules
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

function Update-F5iRuleDatabase {
    param (
        [Parameter(Mandatory=$true)]
        [array]$iRules
    )
    if ($null -eq $iRules) {
        Write-Log -Message ("iRules parameter is null") -LogLevel "ERROR"
        return
    }
    
    # ===============================================================================
    # F5 iRule API Response to Database Field Mapping
    # ===============================================================================
    # F5 API Field     → Database Column    → Description
    # ─────────────────────────────────────────────────────────────────────────────
    # name            → Name               → iRule name (e.g., "AppCache_OWA") 
    # partition       → Partition          → F5 partition (usually "Common")
    # fullPath        → FullPath           → Full path with partition ("/Common/rule_name")
    # kind            → F5ObjectType       → API object type ("tm:ltm:rule:rulehandler")  
    # generation      → Generation         → F5 version/generation number (numeric)
    # selfLink        → F5ApiUrl           → REST API self-reference URL
    # apiAnonymous    → RuleDefinition     → Actual iRule TCL code/script
    # (script-added)  → F5Node             → Source F5 node identifier  
    # (script-added)  → DateAdded          → Collection timestamp
    # ===============================================================================
    
    try {
        $insertCount = 0
        $skippedCount = 0
        if ($iRules.Count -eq 0) {
            Write-Log -Message ("No F5 iRules found to insert into the database") -LogLevel "WARNING"
            return
        }
        Write-Log -Message ("Processing {0} F5 iRules for database update" -f $iRules.Count) -LogLevel "INFO"
        foreach ($rule in $iRules) {
            if (-not (Test-ValidF5iRuleObject $rule)) {
                Write-Log -Message ("SKIP: Invalid iRule object: {0}" -f ($rule | ConvertTo-Json -Compress)) -LogLevel "WARNING"
                $skippedCount++
                continue
            }
            $escapedF5Node = ConvertTo-SqlString $rule 'F5Node'
            $escapedName = ConvertTo-SqlString $rule 'name'
            $escapedFullPath = ConvertTo-SqlString $rule 'fullPath'
            $escapedPartition = ConvertTo-SqlString $rule 'partition'
            $escapedKind = ConvertTo-SqlString $rule 'kind'
            $escapedSelfLink = ConvertTo-SqlString $rule 'selfLink'
            
            # Handle the iRule definition (code) - this is in the apiAnonymous field
            $ruleDefinition = ""
            if ($rule.PSObject.Properties['apiAnonymous'] -and $rule.apiAnonymous) {
                $ruleDefinition = [string]$rule.apiAnonymous
                $ruleDefinition = $ruleDefinition.Replace("'", "''")
            }
            
            # Handle generation (numeric field)
            $generation = 0
            if ($rule.PSObject.Properties['generation'] -and $rule.generation) {
                try {
                    $generation = [int]$rule.generation
                } catch {
                    $generation = 0
                }
            }
            
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
            
            # Log key field values for debugging
            Write-Log -Message ("Processing iRule: F5Node='{0}', Name='{1}', FullPath='{2}', Definition Length={3}" -f $escapedF5Node, $escapedName, $escapedFullPath, $ruleDefinition.Length) -LogLevel "DEBUG"
            Write-Log -Message ("Field values - Partition: '{0}', F5ObjectType: '{1}', Generation: {2}, F5ApiUrl: '{3}'" -f $escapedPartition, $escapedKind, $generation, $escapedSelfLink) -LogLevel "DEBUG"
            
            # Create the MERGE query for the f5iRules table
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
        [RuleDefinition] = N'$ruleDefinition',
        [DateAdded] = '$dateAdded'
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [F5ObjectType], [Generation], [F5ApiUrl], [RuleDefinition], [DateAdded])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', NULLIF(N'$escapedPartition', ''), NULLIF(N'$escapedKind', ''), $generation, NULLIF(N'$escapedSelfLink', ''), N'$ruleDefinition', '$dateAdded');
"@
            try {
                Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery -ErrorAction Stop
                $insertCount++
                Write-Log -Message ("Successfully processed iRule: {0} on node {1}" -f $rule.name, $rule.F5Node) -LogLevel "DEBUG"
            } catch {
                $sqlError = $_.Exception.Message
                Write-Log -Message ("SQL ERROR: {0} | Query: {1}" -f $sqlError, $mergeQuery) -LogLevel "ERROR"
            }
        }
        Write-Log -Message ("Successfully upserted {0} F5 iRules into the database. Skipped {1} with invalid data." -f $insertCount, $skippedCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update F5 iRule database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

# =====================================================
# MAIN SCRIPT EXECUTION SECTION
# =====================================================

try {
    Write-Log -Message ("Starting F5 iRule collection script execution") -LogLevel "INFO"
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
    Write-Log -Message ("Starting iRule collection from F5 nodes") -LogLevel "INFO"
    $iRules = Get-F5iRuleMetadata -F5Nodes $f5Nodes
    if ($null -eq $iRules) {
        Write-Log -Message ("iRule collection returned null. Check previous errors.") -LogLevel "ERROR"
    } elseif ($iRules.Count -eq 0) {
        Write-Log -Message ("No iRules found across any F5 nodes. Check for connection issues.") -LogLevel "WARNING"
    } else {
        Write-Log -Message ("Collected {0} iRules from F5 nodes" -f $iRules.Count) -LogLevel "INFO"

        # Update the database with the collected iRules
        Update-F5iRuleDatabase -iRules $iRules
    }
    Write-Log -Message ("F5 iRule collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 iRule collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}

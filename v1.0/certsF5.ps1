# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory" 
$Table = "certsF5" #Also used for $ScriptName
$ScriptName = $Table # Name for logging purposes
$LogTable = "collectionLogs"
$verboseLogging = $false
$ErrorActionPreference = 'Continue'

# =====================
# Credential Management
# WARNING: Hardcoded credentials are a security risk!
# Consider using Windows Credential Manager, Azure Key Vault, or encrypted config files
# =====================
$UserName = "svc.prod.maint" # The service account with LTM read access
$Password = "REDACTED_F5_PASSWORD" # TODO: Move to secure credential store 
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($UserName, $SecurePassword)

# Import required assemblies
Add-Type -AssemblyName System.Web

# =====================
# Bypass SSL/TLS certificate validation for all .NET requests (for testing only, SQL Agent compatible)
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
    return
}

function ConvertTo-DateTime {
    param(
        $InputDate,
        [string]$ContextName = "date",
        [switch]$AsString,
        [switch]$ToLocalTime,
        [switch]$FromEpoch
    )
    
    if ($null -eq $InputDate -or ($InputDate -is [string] -and [string]::IsNullOrEmpty($InputDate)) -or ($InputDate -is [ValueType] -and $InputDate -eq 0)) { 
        return if ($AsString) { "" } else { $null }
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
                    return if ($AsString) { [string]$InputDate } else { $null }
                }
                $epoch = $epoch[0]
            }
            
            # Parse the epoch timestamp
            if ($epoch -is [string]) {
                if (-not [double]::TryParse($epoch, [ref]$epochNum)) {
                    Write-Log -Message ("Failed to parse epoch value '{0}' as number" -f $epoch) -LogLevel "WARNING"
                    return if ($AsString) { [string]$InputDate } else { $null }
                }
            } elseif ($epoch -is [int] -or $epoch -is [long] -or $epoch -is [double]) {
                $epochNum = [double]$epoch
            } else {
                Write-Log -Message ("Unsupported type for epoch conversion: {0}" -f $epoch.GetType().FullName) -LogLevel "WARNING"
                return if ($AsString) { [string]$InputDate } else { $null }
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
                return if ($AsString) { [string]$InputDate } else { $null }
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
        return if ($AsString) { [string]$InputDate } else { $null }
    }
}

function Format-Thumbprint {
    param([string]$thumbprint)
    if ([string]::IsNullOrEmpty($thumbprint)) { return $thumbprint }
    
    # Remove SHA256/ prefix if present
    $normalized = $thumbprint
    if ($normalized -match "^SHA256/(.+)$") {
        $normalized = $matches[1]
    }
    
    # Remove colons
    $normalized = $normalized -replace ":", ""
    
    # Convert to uppercase for consistency
    $normalized = $normalized.ToUpper()
    
    return $normalized
}

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
# CERTIFICATE VALIDATION AND OBJECT CREATION SECTION
# =====================================================

function Test-ValidF5CertObject {
    param([object]$obj)
    
    if ($null -eq $obj) {
        Write-Log -Message ("Certificate object is null") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not ($obj -is [PSCustomObject])) {
        Write-Log -Message ("Certificate object is not PSCustomObject: {0}" -f $obj.GetType().FullName) -LogLevel "DEBUG"
        return $false
    }
    
    if ($obj.PSObject.Properties.Count -eq 0) {
        Write-Log -Message ("Certificate object has no properties") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['Thumbprint']) {
        Write-Log -Message ("Certificate object missing Thumbprint property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.Thumbprint)) {
        Write-Log -Message ("Certificate Thumbprint is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    if (-not $obj.PSObject.Properties['F5Node']) {
        Write-Log -Message ("Certificate object missing F5Node property. Available properties: {0}" -f ($obj.PSObject.Properties.Name -join ', ')) -LogLevel "DEBUG"
        return $false
    }
    
    if ([string]::IsNullOrEmpty($obj.F5Node)) {
        Write-Log -Message ("Certificate F5Node is null or empty") -LogLevel "DEBUG"
        return $false
    }
    
    # Validate thumbprint format
    if ($obj.Thumbprint -notmatch "^[A-F0-9]+$") {
        Write-Log -Message ("Invalid Thumbprint format: '{0}'" -f $obj.Thumbprint) -LogLevel "DEBUG"
        return $false
    }
    
    # Check if thumbprint has reasonable length
    if ([string]::IsNullOrEmpty($obj.Thumbprint) -or $obj.Thumbprint.Length -ne 64) {
        Write-Log -Message ("Invalid thumbprint length: '{0}' (length: {1})" -f $obj.Thumbprint, $obj.Thumbprint.Length) -LogLevel "DEBUG"
        return $false
    }
    
    return $true
}

function New-F5CertificateObject {
    param(
        [string]$certName,
        [PSObject]$certDetails,
        [string]$rawThumbprint,
        [AllowNull()][DateTime]$certFromTime,
        [AllowNull()][DateTime]$certToTime,
        [PSObject]$sslProfile,
        [string]$f5Node,
        [string]$source = "",
        [bool]$isChain = $false
    )
    
    # Normalize the thumbprint
    $normalizedThumbprint = if (![string]::IsNullOrEmpty($rawThumbprint)) { 
        Format-Thumbprint $rawThumbprint 
    } else { 
        $null 
    }
    
    # Create the certificate object
    $cert = [PSCustomObject]@{
        Name = $certName
        Subject = if ($null -ne $certDetails.subject) { $certDetails.subject } else { "" }
        Issuer = if ($null -ne $certDetails.issuer) { $certDetails.issuer } else { "" }
        Thumbprint = $normalizedThumbprint
        OriginalThumbprint = $rawThumbprint
        ValidFrom = $certFromTime
        ValidTo = $certToTime
        ProfileName = $sslProfile.name
        FullPath = $sslProfile.fullPath
        F5Node = $f5Node
        SubjectAlternativeName = $certDetails.subjectAlternativeName
        SerialNumber = $certDetails.serialNumber
        KeyType = $certDetails.keyType
    }
    
    # Add optional properties based on parameters
    if ($isChain) {
        $cert | Add-Member -NotePropertyName "IsChain" -NotePropertyValue $true -Force
    }
    
    if (![string]::IsNullOrEmpty($source)) {
        $cert | Add-Member -NotePropertyName "Source" -NotePropertyValue $source -Force
    }
    
    return $cert
}

function Get-F5CertificateDetails {
    param(
        [Parameter(Mandatory=$true)]$Session,
        [Parameter(Mandatory=$true)][string]$certName,
        [Parameter(Mandatory=$true)][string]$profileName,
        [Parameter(Mandatory=$true)][PSObject]$sslProfile,
        [string]$certType = "certificate"
    )
    
    try {
        $encodedCertName = [System.Web.HttpUtility]::UrlEncode($certName)
        $certUri = ("{0}sys/file/ssl-cert/{1}" -f ($Session.BaseURL -replace 'ltm/$', ''), $encodedCertName)
        
        Write-Log -Message ("Requesting {0} details from: {1}" -f $certType, $certUri) -LogLevel "DEBUG"
        
        $certDetails = $null
        try {
            $certDetails = Invoke-RestMethodOverride -Method Get -Uri $certUri -WebSession $Session.WebSession -ErrorAction Stop
            
            if ($null -eq $certDetails -or ($certDetails -is [string] -and $certDetails -match "error|exception|failure")) {
                Write-Log -Message ("{0} details for '{1}' returned unexpected value: {2}" -f $certType, $certName, $certDetails) -LogLevel "WARNING"
                return $null
            }
            
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Log -Message ("Failed to retrieve {0} '{1}' for profile '{2}': {3}" -f $certType, $certName, $profileName, $errorMessage) -LogLevel "ERROR"
            return $null
        }
        
        if ($null -eq $certDetails) {
            Write-Log -Message ("{0} details are null for {1} in profile {2}" -f $certType, $certName, $profileName) -LogLevel "WARNING"
            return $null
        }
        
        # Parse dates using helper function
        $certFromTime = ConvertTo-DateTime -InputDate $certDetails.createTime -ContextName "$certType createTime" -ToLocalTime
        $certToTime = $null
        
        if ($null -ne $certDetails.expirationDate -and $certDetails.expirationDate -ne 0) { 
            $certToTime = ConvertTo-DateTime -InputDate $certDetails.expirationDate -ContextName "$certType expirationDate" -FromEpoch -ToLocalTime
        } elseif ($null -ne $certDetails.expirationString -and ![string]::IsNullOrEmpty($certDetails.expirationString)) { 
            $certToTime = ConvertTo-DateTime -InputDate $certDetails.expirationString -ContextName "$certType expirationString" -ToLocalTime
        }
        
        # Extract the raw thumbprint
        $rawThumbprint = if ($null -ne $certDetails.fingerprint -and ![string]::IsNullOrEmpty($certDetails.fingerprint)) { $certDetails.fingerprint } else { $null }
        
        return @{
            CertDetails = $certDetails
            CertFromTime = $certFromTime
            CertToTime = $certToTime
            RawThumbprint = $rawThumbprint
        }
        
    } catch {
        Write-Log -Message ("Exception processing {0} for profile {1}: {2}" -f $certType, $profileName, $_.Exception.Message) -LogLevel "ERROR"
        return $null
    }
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

function Update-F5CertificateDatabase {
    param (
        [Parameter(Mandatory=$true)]
        [array]$certificates,
        [bool]$verboseLogging = $false
    )
    if ($null -eq $certificates) {
        Write-Log ("Certificates parameter is null") "ERROR"
        return
    }
    try {
        $mergeCount = 0
        $skippedCount = 0
        if ($certificates.Count -eq 0) {
            Write-Log ("No F5 certificates found to insert into the database") "WARNING"
            return
        }
        Write-Log ("Processing {0} F5 certificates" -f $certificates.Count) "INFO"
        foreach ($cert in $certificates) {
            # Debug logging to understand the certificate structure
            if ($Script:verboseLogging) {
                Write-Log ("DEBUG: Processing certificate object. Properties: {0}, Thumbprint: '{1}', F5Node: '{2}', ProfileName: '{3}'" -f ($cert.PSObject.Properties.Name -join ', '), $cert.Thumbprint, $cert.F5Node, $cert.ProfileName) "DEBUG"
            }
            
            # Skip certificates with missing or empty Thumbprint
            if (-not $cert.PSObject.Properties['Thumbprint'] -or [string]::IsNullOrEmpty($cert.Thumbprint)) {
                $f5NodeValue = if ($cert.PSObject.Properties['F5Node'] -and $cert.F5Node) { $cert.F5Node } else { "NULL" }
                $profileValue = if ($cert.PSObject.Properties['ProfileName'] -and $cert.ProfileName) { $cert.ProfileName } else { "NULL" }
                $originalThumbprint = if ($cert.PSObject.Properties['OriginalThumbprint'] -and $cert.OriginalThumbprint) { $cert.OriginalThumbprint } else { "NULL" }
                $availableProps = $cert.PSObject.Properties.Name -join ', '
                Write-Log ("Skipping certificate with empty or invalid Thumbprint (F5Node: {0}, Profile: {1}, Original: '{2}', Available Properties: {3})" -f $f5NodeValue, $profileValue, $originalThumbprint, $availableProps) "WARNING"
                $skippedCount++
                continue
            }
            # Escape all relevant certificate fields for SQL
            $escapedF5Node = ConvertTo-SqlString $cert 'F5Node'
            $escapedProfileName = ConvertTo-SqlString $cert 'ProfileName'
            $escapedSubject = ConvertTo-SqlString $cert 'Subject'
            $escapedIssuer = ConvertTo-SqlString $cert 'Issuer'
            $escapedThumbprint = $cert.Thumbprint.Replace("'", "''")  # Thumbprint is already normalized
            $escapedName = ConvertTo-SqlString $cert 'Name'
            $escapedFullPath = ConvertTo-SqlString $cert 'FullPath'
            $escapedSAN = ConvertTo-SqlString $cert 'SubjectAlternativeName'
            $escapedSerialNumber = ConvertTo-SqlString $cert 'SerialNumber'
            $escapedKeyType = ConvertTo-SqlString $cert 'KeyType'
            $validFromStr = ConvertTo-DateTime -InputDate $cert.ValidFrom -AsString
            $validToStr = ConvertTo-DateTime -InputDate $cert.ValidTo -AsString
            $escapedNotes = ConvertTo-SqlString $cert 'Notes'
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedThumbprint' AS [Thumbprint],
    N'$escapedF5Node' AS [F5Node]
) AS Source
ON Target.[Thumbprint] = Source.[Thumbprint] AND Target.[F5Node] = Source.[F5Node]
WHEN MATCHED THEN
    UPDATE SET
        [ProfileName] = N'$escapedProfileName',
        [Subject] = N'$escapedSubject',
        [Issuer] = N'$escapedIssuer',
        [ValidFrom] = '$validFromStr',
        [ValidTo] = '$validToStr',
        [DateAdded] = '$dateAdded',
        [Notes] = NULLIF(N'$escapedNotes', ''),
        [Name] = N'$escapedName',
        [FullPath] = N'$escapedFullPath',
        [SubjectAlternativeName] = N'$escapedSAN',
        [SerialNumber] = N'$escapedSerialNumber',
        [KeyType] = N'$escapedKeyType'
WHEN NOT MATCHED THEN
    INSERT ([Thumbprint], [F5Node], [DateAdded], [ProfileName], [Subject], [Issuer], [ValidFrom], [ValidTo], [Notes], [Name], [FullPath], [SubjectAlternativeName], [SerialNumber], [KeyType])
    VALUES (N'$escapedThumbprint', N'$escapedF5Node', '$dateAdded', N'$escapedProfileName', N'$escapedSubject', N'$escapedIssuer', '$validFromStr', '$validToStr', NULLIF(N'$escapedNotes', ''), N'$escapedName', N'$escapedFullPath', N'$escapedSAN', N'$escapedSerialNumber', N'$escapedKeyType');
"@
            if ($Script:verboseLogging) { Write-Host ("[DEBUG] SQL Merge Query: {0}" -f $mergeQuery) }
            try {
                Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery -ErrorAction Stop
                $mergeCount++
            } catch {
                $sqlError = $_.Exception.Message
                Write-Log -Message ("SQL ERROR: {0} | Query: {1}" -f $sqlError, $mergeQuery) -LogLevel "ERROR"
            }
        }
        Write-Log ("Successfully upserted {0} F5 certificates into the database. Skipped {1} certificates with invalid data." -f $mergeCount, $skippedCount) "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log $errorMessage "ERROR"
        Write-Log ("Failed to update F5 certificate database. Error: {0}" -f $_.Exception.Message) "ERROR"
    }
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
                foreach ($profileName in $Name) {
                    $encodedName = [System.Web.HttpUtility]::UrlEncode($profileName)
                    $uri = "{0}profile/client-ssl/{1}?$select=name,fullPath,cert,key,chain,certExtensionIncludes,certLifespan,chainCA,cipherGroup,crlFile,defaultsFrom,description,forwardProxyBypassDefaultAction,genericAlert,handshakeTimeout,inheritCertkeychain,inheritCiphers,inheritOptions,insertEmptyFragments,modSslMethods,tmOptions,secureRenegotiation,sniDefault,sniRequire&expandSubcollections=true" -f $Session.BaseURL, $encodedName
                    $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                    $result | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session
                    $result
                }
            } else {
                $uri = $Session.BaseURL + "profile/client-ssl"
                if ($Partition -ne '') {
                    $uri += "?`$filter=partition+eq+$Partition"
                }
                $result = Invoke-RestMethodOverride -Method Get -Uri $uri -WebSession $Session.WebSession -ErrorAction Stop
                if ($result.items) {
                    foreach ($item in $result.items) {
                        $item | Add-Member -MemberType NoteProperty -Name "F5Session" -Value $Session
                    }
                    return $result.items
                } else {
                    return @()
                }
            }
        } catch {
            Write-Error ("Error retrieving SSL profile: {0}" -f $_)
            return $null
        }
    }
}

function Get-F5Certificate {
    [cmdletBinding()]
    param (
        $Session,
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$Partition = "Common"
    )
    begin {
        if ($null -eq $Session) {
            Write-Log -Message ("No F5 session specified") -LogLevel "ERROR"
            throw "No F5 session specified"
        }
    }
    process {
        $certificates = @()
        $certCount = 0

        try {
            $encodedName = [System.Web.HttpUtility]::UrlEncode($Name)
            $profileUri = "{0}profile/client-ssl/{1}" -f $Session.BaseURL, $encodedName
            
            Write-Log -Message ("Requesting SSL profile from: {0}" -f $profileUri) -LogLevel "DEBUG"
            
            $sslProfile = $null
            try {
                $sslProfile = Invoke-RestMethodOverride -Method Get -Uri $profileUri -WebSession $Session.WebSession -ErrorAction Stop
                
                if ($null -eq $sslProfile -or ($sslProfile -is [string] -and $sslProfile -match "error|exception|failure")) {
                    Write-Log -Message ("SSL profile '{0}' returned unexpected value: {1}" -f $Name, $sslProfile) -LogLevel "WARNING"
                    return @() # Return empty array
                }
                
                Write-Log -Message ("Successfully retrieved SSL profile: {0}" -f $Name) -LogLevel "DEBUG"
            } catch {
                $errorMessage = $_.Exception.Message
                
                Write-Log -Message ("Failed to retrieve SSL profile '{0}': {1}" -f $Name, $errorMessage) -LogLevel "ERROR"
                return @() # Return empty array instead of null
            }
            
            if ($null -eq $sslProfile) {
                Write-Log -Message ("SSL profile '{0}' returned null" -f $Name) -LogLevel "ERROR"
                return @() # Return empty array instead of null
            }
            
            if ($null -ne $sslProfile.cert -and ![string]::IsNullOrEmpty($sslProfile.cert) -and $sslProfile.cert -ne "none") {
                $certName = ($sslProfile.cert -split "/")[-1]
                if ([string]::IsNullOrEmpty($certName) -or $certName -eq "none") {
                    Write-Log -Message ("Invalid certificate reference in profile {0}" -f $Name) -LogLevel "WARNING"
                } else {
                    $certInfo = Get-F5CertificateDetails -Session $Session -certName $certName -profileName $Name -sslProfile $sslProfile -certType "certificate"
                    
                    if ($null -ne $certInfo) {
                        # Create certificate object using helper function
                        $cert = New-F5CertificateObject -certName $certName -certDetails $certInfo.CertDetails -rawThumbprint $certInfo.RawThumbprint `
                            -certFromTime $certInfo.CertFromTime -certToTime $certInfo.CertToTime -sslProfile $sslProfile -f5Node $Session.Name
                        
                        Write-Log -Message ("Created certificate object: Name='{0}', Thumbprint='{1}', Original='{2}', Subject='{3}', F5Node='{4}'" -f 
                            $cert.Name, $cert.Thumbprint, $cert.OriginalThumbprint, $cert.Subject, $cert.F5Node) -LogLevel "DEBUG"
                        
                        if (Test-ValidF5CertObject $cert) {
                            Write-Log -Message ("Certificate passed validation: {0}" -f $cert.Name) -LogLevel "DEBUG"
                            $certificates += $cert
                            $certCount++
                        } else {
                            Write-Log -Message ("Certificate failed validation: {0} (Thumbprint: '{1}', Original: '{2}')" -f $cert.Name, $cert.Thumbprint, $cert.OriginalThumbprint) -LogLevel "WARNING"
                        }
                    }
                }
            } else {
                Write-Log -Message ("No valid certificate reference found in profile {0}" -f $Name) -LogLevel "DEBUG"
            }
            
            if ($null -ne $sslProfile.chain -and ![string]::IsNullOrEmpty($sslProfile.chain) -and $sslProfile.chain -ne "none") {
                $chainName = ($sslProfile.chain -split "/")[-1]
                if ([string]::IsNullOrEmpty($chainName) -or $chainName -eq "none") {
                    Write-Log -Message ("Invalid chain certificate reference in profile {0}" -f $Name) -LogLevel "WARNING"
                } else {
                    $chainInfo = Get-F5CertificateDetails -Session $Session -certName $chainName -profileName $Name -sslProfile $sslProfile -certType "chain certificate"
                    
                    if ($null -ne $chainInfo) {
                        # Create chain certificate object using helper function
                        $chainCert = New-F5CertificateObject -certName $chainName -certDetails $chainInfo.CertDetails -rawThumbprint $chainInfo.RawThumbprint `
                            -certFromTime $chainInfo.CertFromTime -certToTime $chainInfo.CertToTime -sslProfile $sslProfile -f5Node $Session.Name -isChain $true
                        
                        Write-Log -Message ("Created chain certificate object: Name='{0}', Thumbprint='{1}', Original='{2}', Subject='{3}', F5Node='{4}'" -f 
                            $chainCert.Name, $chainCert.Thumbprint, $chainCert.OriginalThumbprint, $chainCert.Subject, $chainCert.F5Node) -LogLevel "DEBUG"
                        
                        if (Test-ValidF5CertObject $chainCert) {
                            Write-Log -Message ("Chain certificate passed validation: {0}" -f $chainCert.Name) -LogLevel "DEBUG"
                            $certificates += $chainCert
                            $certCount++
                        } else {
                            Write-Log -Message ("Chain certificate failed validation: {0} (Thumbprint: '{1}', Original: '{2}')" -f $chainCert.Name, $chainCert.Thumbprint, $chainCert.OriginalThumbprint) -LogLevel "WARNING"
                        }
                    }
                }
            }
            
            if ($null -ne $sslProfile.certKeyChain -and ($sslProfile.certKeyChain -is [array] -or $sslProfile.certKeyChain -is [System.Collections.IList]) -and $sslProfile.certKeyChain.Count -gt 0) {
                Write-Log -Message ("Found {0} certKeyChain entries in profile {1}" -f $sslProfile.certKeyChain.Count, $Name) -LogLevel "DEBUG"
                
                foreach ($keyChain in $sslProfile.certKeyChain) {
                    try {
                        if ($null -ne $keyChain -and $null -ne $keyChain.cert -and ![string]::IsNullOrEmpty($keyChain.cert) -and $keyChain.cert -ne "none") {
                            $certPath = $keyChain.cert
                            $certName = ($certPath -split "/")[-1]
                            
                            if ([string]::IsNullOrEmpty($certName) -or $certName -eq "none") {
                                Write-Log -Message ("Invalid certKeyChain certificate reference in profile {0}" -f $Name) -LogLevel "WARNING"
                                continue
                            }
                            
                            $certInfo = Get-F5CertificateDetails -Session $Session -certName $certName -profileName $Name -sslProfile $sslProfile -certType "certKeyChain certificate"
                            
                            if ($null -ne $certInfo) {
                                # Create certificate object using helper function
                                $cert = New-F5CertificateObject -certName $certName -certDetails $certInfo.CertDetails -rawThumbprint $certInfo.RawThumbprint `
                                    -certFromTime $certInfo.CertFromTime -certToTime $certInfo.CertToTime -sslProfile $sslProfile -f5Node $Session.Name -source "certKeyChain"
                                
                                Write-Log -Message ("Created certKeyChain certificate object: Name='{0}', Thumbprint='{1}', Original='{2}', Subject='{3}', F5Node='{4}'" -f 
                                    $cert.Name, $cert.Thumbprint, $cert.OriginalThumbprint, $cert.Subject, $cert.F5Node) -LogLevel "DEBUG"
                                
                                if (Test-ValidF5CertObject $cert) {
                                    Write-Log -Message ("CertKeyChain certificate passed validation: {0}" -f $cert.Name) -LogLevel "DEBUG"
                                    $certificates += $cert
                                    $certCount++
                                } else {
                                    Write-Log -Message ("CertKeyChain certificate failed validation: {0} (Thumbprint: '{1}', Original: '{2}')" -f $cert.Name, $cert.Thumbprint, $cert.OriginalThumbprint) -LogLevel "WARNING"
                                }
                            }
                        }
                    } catch {
                        Write-Log -Message ("Exception processing certKeyChain entry for profile {0}: {1}" -f $Name, $_.Exception.Message) -LogLevel "ERROR"
                    }
                }
            }
            
            Write-Log -Message ("Retrieved {0} certificates for SSL profile '{1}'" -f $certCount, $Name) -LogLevel "INFO"
            return $certificates
        } catch {
            $errorDetails = $_.Exception.Message
            if ($_.ScriptStackTrace) {
                $errorDetails += "`nStack Trace: " + $_.ScriptStackTrace
            }
            Write-Log -Message ("Unhandled exception in Get-F5Certificate for profile '{0}': {1}" -f $Name, $errorDetails) -LogLevel "ERROR"
            return @() # Return empty array instead of null
        }
    }
}
# =====================================================
# CERTIFICATE COLLECTION AND PROCESSING SECTION
# =====================================================

function Get-F5CertificateMetadata {
    param(
        [Parameter(Mandatory=$true)]
        $f5Nodes,
        [bool]$verboseLogging = $false
    )
    $certificates = @()
    # PowerShell 5.1 compatibility: Use New-Object instead of ::new()
    $uniqueCertKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($nodeKey in $f5Nodes.Keys) {
        foreach ($subNode in $f5Nodes[$nodeKey]) {
            Write-Log ("Processing F5 node: {0}" -f $subNode.Node)
            try {
                $f5Session = $null
                try {
                    $nodeAddress = Get-BestF5NodeAddress $subNode
                    if ($null -eq $nodeAddress -or $nodeAddress -eq '') {
                        Write-Log ("Could not determine address for F5 node: {0}" -f $subNode.Node) "ERROR"
                        continue
                    }
                    $f5Session = New-F5Session -LTMName $nodeAddress -Credential $Credential -ErrorAction Stop -PassThru -TokenLifespan 1200
                    if ($Script:verboseLogging) { Write-Log ("New-F5Session result for node {0}: {1}" -f $nodeAddress, ($f5Session | ConvertTo-Json -Compress)) "DEBUG" }
                } catch {
                    Write-Log ("Exception creating F5 session for node {0}: {1}" -f $nodeAddress, $_.Exception.Message) "ERROR"
                    continue
                }
                if ($null -eq $f5Session) {
                    Write-Log ("Failed to create session for {0}" -f $subNode.Node) "WARNING"
                    continue
                }
                $sslProfiles = $null
                try {
                    $sslProfiles = Get-F5SSLProfile -Session $f5Session -ErrorAction Stop
                    $sslProfiles = $sslProfiles | Where-Object { ($_ -is [PSCustomObject]) -and $_.PSObject.Properties.Count -gt 0 }
                    $sslProfileCount = if ($null -eq $sslProfiles) { 0 } elseif ($sslProfiles.Count -ge 0) { $sslProfiles.Count } else { 0 }
                    if ($Script:verboseLogging) {
                        Write-Log ("Raw sslProfiles result for node {0}: {1}" -f $subNode.Node, ($sslProfiles | ConvertTo-Json -Compress)) "DEBUG"
                    }
                    if ($sslProfileCount -eq 0) {
                        Write-Log ("No SSL profiles found for node {0}" -f $subNode.Node) "INFO"
                    } else {
                        Write-Log ("Found {0} SSL profile(s) for node {1}" -f $sslProfileCount, $subNode.Node) "INFO"
                    }
                } catch {
                    Write-Log ("Exception retrieving SSL profiles for node {0}: {1}" -f $subNode.Node, $_.Exception.Message) "ERROR"
                    continue
                }
                if ($null -eq $sslProfiles -or $sslProfiles.Count -eq 0) {
                    Write-Log ("No SSL profiles returned for node {0}" -f $subNode.Node) "WARNING"
                    continue
                }
                foreach ($sslProfile in $sslProfiles) {
                    $sslCerts = $null
                    try {
                        # Always URL-encode the profile name to avoid special character/encoding issues
                        $encodedProfileName = [System.Web.HttpUtility]::UrlEncode($sslProfile.Name)
                        $sslCerts = Get-F5Certificate -Session $f5Session -Name $encodedProfileName -ErrorAction Stop
                        $sslCerts = $sslCerts | Where-Object { ($_ -is [PSCustomObject]) -and $_.PSObject.Properties.Count -gt 0 }
                        $sslCertCount = if ($null -eq $sslCerts) { 0 } elseif ($sslCerts.Count -ge 0) { $sslCerts.Count } else { 0 }
                        if ($Script:verboseLogging) {
                            Write-Log ("Raw sslCerts result for profile {0} on node {1}: {2}" -f $sslProfile.Name, $subNode.Node, ($sslCerts | ConvertTo-Json -Compress)) "DEBUG"
                        }
                        if ($sslCertCount -eq 0) {
                            Write-Log ("No certificates found for profile {0} on node {1}" -f $sslProfile.Name, $subNode.Node) "INFO"
                        } else {
                            Write-Log ("Found {0} certificate(s) for profile {1} on node {2}" -f $sslCertCount, $sslProfile.Name, $subNode.Node) "INFO"
                        }
                        if ($sslCertCount -eq 0) {
                            Write-Log ("Note: A 404 error may occur here if the profile was just scraped from the F5 but is not yet available for detail queries due to F5 API caching or replication lag.") "INFO"
                        }
                    } catch {
                        Write-Log ("Exception retrieving certificates for profile {0} on node {1}: {2}" -f $sslProfile.Name, $subNode.Node, $_.Exception.Message) "ERROR"
                        continue
                    }
                    if ($null -eq $sslCerts -or $sslCerts.Count -eq 0) {
                        Write-Log ("No certificates returned for profile {0} on {1}" -f $sslProfile.Name, $subNode.Node) "WARNING"
                        continue
                    }
                    foreach ($certificate in $sslCerts) {
                        if ($Script:verboseLogging) {
                            Write-Log -Message ("Processing certificate from profile {0} on node {1}. Raw cert object: {2}" -f $sslProfile.Name, $subNode.Node, ($certificate | ConvertTo-Json -Compress)) -LogLevel "DEBUG"
                        }
                        
                        # Validate the certificate object
                        if (-not (Test-ValidF5CertObject $certificate)) {
                            Write-Log ("Certificate failed validation for profile {0} on node {1}" -f $sslProfile.Name, $subNode.Node) "WARNING"
                            continue
                        }
                        $certKey = "{0}|{1}" -f $certificate.Thumbprint, $certificate.F5Node
                        if ($uniqueCertKeys.Add($certKey)) {
                            $certificates += $certificate
                        }
                    }
                }
                Disconnect-F5LTM -Session $f5Session -ErrorAction Stop
            } catch {
                Write-Log ('Exception processing F5 node {0}: {1}' -f $subNode.Node, $_.Exception.Message) "ERROR"
            }
        }
    }
    Write-Log ("Final certificates array count: {0}" -f $certificates.Count) "INFO"
    if ($Script:verboseLogging) {
        Write-Log ("Final certificates array content: {0}" -f ($certificates | ConvertTo-Json -Compress)) "DEBUG"
    }
    return $certificates
}

# =====================================================
# MAIN SCRIPT EXECUTION SECTION
# =====================================================

try {
    Write-Log -Message ("Starting F5 certificate collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    
    $Script:verboseLogging = $false
    
    $f5Nodes = Get-F5NodesFromDB
    if ($null -eq $f5Nodes -or $f5Nodes.Count -eq 0) {
        Write-Log -Message ("No F5 nodes found in database. Please check f5Nodes table.") -LogLevel "ERROR"
        exit 1
    }
    
    $totalNodes = 0
    foreach ($nodeGroup in $f5Nodes.Keys) {
        $totalNodes += $f5Nodes[$nodeGroup].Count
    }
    Write-Log -Message ("Found {0} F5 node groups with {1} total nodes to process" -f $f5Nodes.Count, $totalNodes) -LogLevel "INFO"
    
    $certificates = Get-F5CertificateMetadata -f5Nodes $f5Nodes -verboseLogging $Script:verboseLogging
    
    if ($null -eq $certificates) {
        Write-Log -Message ("Certificate collection returned null. Check previous errors.") -LogLevel "ERROR"
    } 
    elseif ($certificates.Count -eq 0) {
        Write-Log -Message ("No certificates found across any F5 nodes. Check for connection issues.") -LogLevel "WARNING"
    }
    else {
        Write-Log -Message ("Collected {0} raw certificate entries from F5 nodes" -f $certificates.Count) -LogLevel "INFO"
        Write-Log -Message ("Updating SQL database with collected F5 certificates") -LogLevel "INFO"
        Update-F5CertificateDatabase -certificates $certificates -verboseLogging $Script:verboseLogging
    }
    
    Write-Log -Message ("F5 certificate collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "{0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 certificate collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}

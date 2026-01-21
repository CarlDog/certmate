# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$CertsTable = "f5Certs"
$SSLProfilesTable = "f5SSLProfiles"
$VirtualServersTable = "f5VirtualServers"
$LogTable = "collectionLogs"
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
# Load F5 Nodes from Database
# =====================
function Get-F5NodesFromDB {
    $query = "SELECT Cluster, Node, DisplayName, MgmtFQDN, IPAddress, Location, Environment, DeviceType, IsActive, LastSeen FROM f5Nodes WHERE IsActive = 1"
    $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
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
}

# =====================
# Logging Function
# =====================
function Write-Log {
    param (
        [string]$Message,
        [string]$ScriptName,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[{0}] {1}: {2}" -f $timestamp, $ScriptName, $Message
    try {
        $logId = [System.Guid]::NewGuid().ToString()
        $dbTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $escapedScriptName = $ScriptName.Replace("'", "''")
        $escapedMessage = $Message.Replace("'", "''")
        $escapedLogLevel = $LogLevel.Replace("'", "''")
        if ($null -eq $AdditionalInfo) {
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]
) VALUES (
    '$logId', '$dbTimestamp', N'$escapedScriptName', N'$escapedLogLevel', N'$escapedMessage', NULL
)
"@
        } else {
            $escapedAdditionalInfo = $AdditionalInfo.Replace("'", "''")
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]
) VALUES (
    '$logId', '$dbTimestamp', N'$escapedScriptName', N'$escapedLogLevel', N'$escapedMessage', N'$escapedAdditionalInfo'
)
"@
        }
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction SilentlyContinue
    } catch {
        $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Output ("[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message)
    }
}

# =====================
# Helper: Normalize thumbprint (remove colons, uppercase)
# =====================
function Normalize-Thumbprint {
    param([string]$Thumbprint)
    if ($null -eq $Thumbprint) { return $null }
    return ($Thumbprint -replace ':', '').ToUpper()
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
        $ContentType
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Invoke-RestMethod @PSBoundParameters -SkipCertificateCheck
    } else {
        Invoke-RestMethod @PSBoundParameters
    }
}

function New-F5Session {
    [cmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$LTMName,
        [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$LTMCredentials,
        [switch]$Default,
        [Alias('PassThrough')]
        [switch]$PassThru,
        [ValidateRange(300,36000)][int]$TokenLifespan=1200
    )
    $BaseURL = "https://$LTMName/mgmt/tm/ltm/"
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $AuthURL = "https://$LTMName/mgmt/shared/authn/login"
    $JSONBody = @{username = $LTMCredentials.username; password=$LTMCredentials.GetNetworkCredential().password; loginProviderName='tmos'} | ConvertTo-Json
    try {
        $Result = Invoke-RestMethodOverride -Method POST -Uri $AuthURL -Body $JSONBody -Credential $LTMCredentials -ContentType 'application/json'
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
            if ($LTMError[0] -notmatch 'Unauthorized') { Throw ("The specified LTM name $LTMName is not valid.") }
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
    $VersionURL = $BaseURL.Replace('ltm/','sys/version/')
    $JSON = Invoke-RestMethodOverride -Method Get -Uri $VersionURL -WebSession $session
    $version = '0.0.0.0'
    if ($JSON -match '([0-9]+\.?){3,4}') { $version = [Regex]::Match($JSON,'([0-9]+\.?){3,4}').Value }
    $newSession | Add-Member -Name LTMVersion -Value ([Version]$version) -MemberType NoteProperty
    if ($Default -or !($Script:F5Session)) { $Script:F5Session = $newSession }
    if ($PassThru) { $newSession }
}

function Disconnect-F5LTM {
    [cmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Session
    )
    try {
        if ($Session.Token) {
            $uri = "https://$($Session.Name)/mgmt/shared/authz/tokens/$($Session.Token)"
            $Headers = @{
                'X-F5-Auth-Token' = $Session.Token
            }
            try {
                Invoke-RestMethodOverride -Method DELETE -Uri $uri -Headers $Headers -WebSession $Session.WebSession -ErrorAction Stop | Out-Null
                return $true
            } catch {
                Write-Warning "Could not delete token for session: $_"
                return $false
            }
        }
        return $true
    } catch {
        Write-Warning "Error disconnecting from F5 LTM: $_"
        return $false
    }
}

# =====================
# F5 Data Collection Functions (Node-by-node)
# =====================
function Get-F5Certs {
    param($Session, $NodeName)
    $certificates = @()
    $uniqueThumbprints = [System.Collections.Generic.HashSet[string]]::new()
    try {
        $sslProfiles = Get-F5SSLProfile -Session $Session -ErrorAction Stop
        if ($null -eq $sslProfiles -or $sslProfiles.Count -eq 0) {
            Write-Log -Message ("No SSL profiles returned for node {0}" -f $NodeName) -ScriptName 'certsF5.ps1' -LogLevel "WARNING"
            return @()
        }
        foreach ($profile in $sslProfiles) {
            $sslCerts = $null
            try {
                $sslCerts = Get-F5Certificate -Session $Session -Name $profile.Name -ErrorAction Stop
                if ($null -eq $sslCerts -or $sslCerts.Count -eq 0) { continue }
                foreach ($certificate in $sslCerts) {
                    if ($null -eq $certificate) { continue }
                    if ($certificate -is [string]) { continue }
                    if (-not ($certificate -is [PSCustomObject]) -or -not $certificate.PSObject.Properties) { continue }
                    if ($null -eq $certificate.Thumbprint -or [string]::IsNullOrEmpty($certificate.Thumbprint) -or $null -eq $NodeName) { continue }
                    $thumbprint = $certificate.Thumbprint
                    $certificate.Thumbprint = Normalize-Thumbprint $thumbprint
                    if ($uniqueThumbprints.Add($certificate.Thumbprint)) {
                        $certificates += [pscustomobject]@{
                            F5Node        = $NodeName
                            ProfileName   = $profile.Name
                            Subject       = $certificate.Subject
                            Issuer        = $certificate.Issuer
                            Thumbprint    = $certificate.Thumbprint
                            ValidFrom     = if ($certificate.PSObject.Properties['NotBefore'] -and $null -ne $certificate.NotBefore) { $certificate.NotBefore } elseif ($certificate.PSObject.Properties['ValidFrom'] -and $null -ne $certificate.ValidFrom) { $certificate.ValidFrom } else { $null }
                            ValidTo       = if ($certificate.PSObject.Properties['NotAfter'] -and $null -ne $certificate.NotAfter) { $certificate.NotAfter } elseif ($certificate.PSObject.Properties['ValidTo'] -and $null -ne $certificate.ValidTo) { $certificate.ValidTo } else { $null }
                        }
                    }
                }
            } catch {
                Write-Log -Message ("ERROR: Exception retrieving certificates for profile {0} on node {1}: {2}" -f $profile.Name, $NodeName, $_.Exception.Message) -ScriptName 'certsF5.ps1' -LogLevel "ERROR"
            }
        }
    } catch {
        Write-Log -Message ("ERROR: Exception retrieving SSL profiles for node {0}: {1}" -f $NodeName, $_.Exception.Message) -ScriptName 'certsF5.ps1' -LogLevel "ERROR"
    }
    return $certificates
}

function Get-F5SSLProfiles {
    param($Session, $NodeName)
    $profiles = @()
    try {
        $sslProfiles = Get-F5SSLProfile -Session $Session -ErrorAction Stop
        if ($null -eq $sslProfiles) { return @() }
        foreach ($profile in $sslProfiles) {
            if ($null -eq $profile -or $profile -is [string] -or -not ($profile -is [PSCustomObject]) -or -not $profile.PSObject.Properties) { continue }
            foreach ($field in @('Cert','Chain')) {
                if ($profile.PSObject.Properties[$field] -and $profile.$field) {
                    $profile.$field = Normalize-Thumbprint $profile.$field
                }
            }
            $profile.F5Node = $NodeName
            $profiles += $profile
        }
    } catch {
        Write-Log -Message ("ERROR: Exception retrieving SSL profiles for node {0}: {1}" -f $NodeName, $_.Exception.Message) -ScriptName 'f5SSLProfiles.ps1' -LogLevel "ERROR"
    }
    return $profiles
}

function Get-F5VirtualServers {
    param($Session, $NodeName)
    $virtualServers = @()
    try {
        $vsList = Get-F5VirtualServer -Session $Session -ErrorAction Stop
        if ($null -eq $vsList) { return @() }
        foreach ($vs in $vsList) {
            if ($null -eq $vs) { continue }
            if ($vs -is [string]) { continue }
            if (-not ($vs -is [PSCustomObject]) -or -not $vs.PSObject.Properties) { continue }
            $virtualServers += [pscustomobject]@{
                F5Node        = $NodeName
                Name          = $vs.name
                FullPath      = $vs.fullPath
                Partition     = $vs.partition
                Destination   = $vs.destination
                IP            = ($vs.destination -split ":")[0]
                Port          = ($vs.destination -split ":")[1]
                Enabled       = $vs.enabled
                Description   = $vs.description
                Profiles      = ($vs.profiles | ForEach-Object { $_.name }) -join ","
                Rules         = ($vs.rules -join ",")
                Source        = $vs.source
                Mask          = $vs.mask
                Pool          = $vs.pool
                SNAT          = $vs.snat
                VLANs         = ($vs.vlans -join ",")
                LastModified  = $vs.lastModified
                Notes         = $vs.notes
            }
        }
    } catch {
        Write-Log -Message ("ERROR: Exception retrieving virtual servers for node {0}: {1}" -f $NodeName, $_.Exception.Message) -ScriptName 'f5VirtualServers.ps1' -LogLevel "ERROR"
    }
    return $virtualServers
}

# =====================
# Database Update Functions (using table variables)
# =====================
function Update-F5CertificateDatabase {
    param (
        [array]$certificates,
        [string]$TableName
    )
    try {
        $mergeCount = 0
        $filteredCertificates = @()
        $invalidCount = 0
        foreach ($cert in $certificates) {
            if ($null -eq $cert) { $invalidCount++; continue }
            if ($cert -is [string]) { $invalidCount++; continue }
            if (-not ($cert -is [PSCustomObject]) -or -not $cert.PSObject.Properties) { $invalidCount++; continue }
            if ([string]::IsNullOrEmpty($cert.Thumbprint) -or [string]::IsNullOrEmpty($cert.F5Node)) { $invalidCount++; continue }
            $filteredCertificates += $cert
        }
        if ($filteredCertificates.Count -eq 0) { return }
        foreach ($cert in $filteredCertificates) {
            $escapedF5Node = $cert.F5Node.Replace("'", "''")
            $escapedProfileName = $cert.ProfileName.Replace("'", "''")
            $escapedSubject = $cert.Subject.Replace("'", "''")
            $escapedIssuer = $cert.Issuer.Replace("'", "''")
            $escapedThumbprint = $cert.Thumbprint.Replace("'", "''")
            $validFromStr = if ($cert.ValidFrom) { $cert.ValidFrom } else { "" }
            $validToStr = if ($cert.ValidTo) { $cert.ValidTo } else { "" }
            $escapedNotes = if ($cert.Notes) { $cert.Notes.Replace("'", "''") } else { "" }
            $certificateId = [guid]::NewGuid().ToString()
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            $mergeQuery = @"
MERGE INTO [$TableName] AS Target
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
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([Thumbprint], [F5Node], [CertificateId], [DateAdded], [ProfileName], [Subject], [Issuer], [ValidFrom], [ValidTo], [Notes])
    VALUES (N'$escapedThumbprint', N'$escapedF5Node', '$certificateId', '$dateAdded', N'$escapedProfileName', N'$escapedSubject', N'$escapedIssuer', '$validFromStr', '$validToStr', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $mergeCount++
        }
        Write-Log -Message ("Successfully upserted {0} F5 certificates into the database." -f $mergeCount) -ScriptName 'certsF5' -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -ScriptName 'certsF5' -LogLevel "ERROR"
    }
}

function Update-F5SSLProfileDatabase {
    param (
        [array]$profiles,
        [string]$TableName
    )
    try {
        $insertCount = 0
        foreach ($profile in $profiles) {
            if ($null -eq $profile -or $profile -is [string] -or -not ($profile -is [PSCustomObject]) -or -not $profile.PSObject.Properties) { continue }
            $escapedF5Node = if ($profile.F5Node) { $profile.F5Node.Replace("'", "''") } else { "" }
            $escapedName = if ($profile.Name) { $profile.Name.Replace("'", "''") } else { "" }
            $escapedFullPath = if ($profile.FullPath) { $profile.FullPath.Replace("'", "''") } else { "" }
            $escapedPartition = if ($profile.Partition) { $profile.Partition.Replace("'", "''") } else { "" }
            $escapedCert = if ($profile.Cert) { $profile.Cert.Replace("'", "''") } else { "" }
            $escapedChain = if ($profile.Chain) { $profile.Chain.Replace("'", "''") } else { "" }
            $escapedKey = if ($profile.Key) { $profile.Key.Replace("'", "''") } else { "" }
            $escapedDescription = if ($profile.Description) { $profile.Description.Replace("'", "''") } else { "" }
            $escapedCipherGroup = if ($profile.CipherGroup) { $profile.CipherGroup.Replace("'", "''") } else { "" }
            $escapedNotes = if ($null -ne $profile.Notes) { $profile.Notes.Replace("'", "''") } else { "" }
            $escapedSubject = if ($profile.Subject) { $profile.Subject.Replace("'", "''") } else { "" }
            $escapedIssuer = if ($profile.Issuer) { $profile.Issuer.Replace("'", "''") } else { "" }
            $validFromStr = if ($profile.ValidFrom) { $profile.ValidFrom } else { "" }
            $validToStr = if ($profile.ValidTo) { $profile.ValidTo } else { "" }
            $mergeQuery = @"
MERGE INTO [$TableName] AS Target
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
        [Subject] = N'$escapedSubject',
        [Issuer] = N'$escapedIssuer',
        [ValidFrom] = '$validFromStr',
        [ValidTo] = '$validToStr',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [Cert], [Chain], [SSLKey], [Description], [CipherGroup], [Subject], [Issuer], [ValidFrom], [ValidTo], [Notes])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', N'$escapedPartition', N'$escapedCert', N'$escapedChain', N'$escapedKey', N'$escapedDescription', N'$escapedCipherGroup', N'$escapedSubject', N'$escapedIssuer', '$validFromStr', '$validToStr', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $insertCount++
        }
        Write-Log -Message ("Successfully upserted {0} F5 SSL profiles into the database." -f $insertCount) -ScriptName 'f5SSLProfiles' -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -ScriptName 'f5SSLProfiles' -LogLevel "ERROR"
    }
}

function Update-F5VirtualServerDatabase {
    param (
        [array]$virtualServers,
        [string]$TableName
    )
    try {
        $insertCount = 0
        foreach ($vs in $virtualServers) {
            $escapedF5Node = if ($vs.F5Node) { $vs.F5Node.Replace("'", "''") } else { "" }
            $escapedName = if ($vs.Name) { $vs.Name.Replace("'", "''") } else { "" }
            $escapedFullPath = if ($vs.FullPath) { $vs.FullPath.Replace("'", "''") } else { "" }
            $escapedPartition = if ($vs.Partition) { $vs.Partition.Replace("'", "''") } else { "" }
            $escapedDestination = if ($vs.Destination) { $vs.Destination.Replace("'", "''") } else { "" }
            $escapedIP = if ($vs.IP) { $vs.IP.Replace("'", "''") } else { "" }
            $escapedPort = if ($vs.Port) { $vs.Port.Replace("'", "''") } else { "" }
            $escapedDescription = if ($vs.Description) { $vs.Description.Replace("'", "''") } else { "" }
            $escapedProfiles = if ($vs.Profiles) { $vs.Profiles.Replace("'", "''") } else { "" }
            $escapedRules = if ($vs.Rules) { $vs.Rules.Replace("'", "''") } else { "" }
            $escapedSource = if ($vs.Source) { $vs.Source.Replace("'", "''") } else { "" }
            $escapedMask = if ($vs.Mask) { $vs.Mask.Replace("'", "''") } else { "" }
            $escapedPool = if ($vs.Pool) { $vs.Pool.Replace("'", "''") } else { "" }
            $escapedSNAT = if ($vs.SNAT) { $vs.SNAT.Replace("'", "''") } else { "" }
            $escapedVLANs = if ($vs.VLANs) { $vs.VLANs.Replace("'", "''") } else { "" }
            $escapedNotes = if ($null -ne $vs.Notes) { $vs.Notes.Replace("'", "''") } else { "" }
            $mergeQuery = @"
MERGE INTO [$TableName] AS Target
USING (SELECT
    N'$escapedF5Node' AS [F5Node],
    N'$escapedName' AS [Name]
) AS Source
ON Target.[F5Node] = Source.[F5Node] AND Target.[Name] = Source.[Name]
WHEN MATCHED THEN
    UPDATE SET
        [FullPath] = N'$escapedFullPath',
        [Partition] = N'$escapedPartition',
        [Destination] = N'$escapedDestination',
        [IP] = N'$escapedIP',
        [Port] = N'$escapedPort',
        [Description] = N'$escapedDescription',
        [Profiles] = N'$escapedProfiles',
        [Rules] = N'$escapedRules',
        [Source] = N'$escapedSource',
        [Mask] = N'$escapedMask',
        [Pool] = N'$escapedPool',
        [SNAT] = N'$escapedSNAT',
        [VLANs] = N'$escapedVLANs',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([F5Node], [Name], [FullPath], [Partition], [Destination], [IP], [Port], [Description], [Profiles], [Rules], [Source], [Mask], [Pool], [SNAT], [VLANs], [Notes])
    VALUES (N'$escapedF5Node', N'$escapedName', N'$escapedFullPath', N'$escapedPartition', N'$escapedDestination', N'$escapedIP', N'$escapedPort', N'$escapedDescription', N'$escapedProfiles', N'$escapedRules', N'$escapedSource', N'$escapedMask', N'$escapedPool', N'$escapedSNAT', N'$escapedVLANs', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $insertCount++
        }
        Write-Log -Message ("Successfully upserted {0} F5 virtual servers into the database." -f $insertCount) -ScriptName 'f5VirtualServers' -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -ScriptName 'f5VirtualServers' -LogLevel "ERROR"
    }
}
# =====================
# Main Script Logic
# =====================
try {
    Write-Log -Message "Starting F5 inventory collection script execution" -ScriptName 'f5Inventory' -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -ScriptName 'f5Inventory' -LogLevel "INFO"
    $f5Nodes = Get-F5NodesFromDB
    foreach ($cluster in $f5Nodes.Keys) {
        foreach ($nodeObj in $f5Nodes[$cluster]) {
            $node = $nodeObj.Node
            $ip = $nodeObj.IPAddress
            $displayName = $nodeObj.DisplayName
            # --- Certs ---
            $ScriptName = 'certsF5'
            Write-Log -Message ("Processing F5 node for certs: {0}" -f $node) -ScriptName $ScriptName
            try {
                $f5Session = New-F5Session -LTMName $node -LTMCredentials $Credential -ErrorAction Stop -PassThru $true
                $certs = Get-F5Certs -Session $f5Session -NodeName $node
                if ($certs -and $certs.Count -gt 0) {
                    Update-F5CertificateDatabase -certificates $certs -TableName $CertsTable
                    Write-Log -Message ("Upserted {0} certs for node {1}" -f $certs.Count, $node) -ScriptName $ScriptName
                } else {
                    Write-Log -Message ("No certs found for node {0}" -f $node) -ScriptName $ScriptName -LogLevel "WARNING"
                }
                Disconnect-F5LTM -Session $f5Session | Out-Null
            } catch {
                Write-Log -Message ("ERROR collecting certs for node {0}: {1}" -f $node, $_.Exception.Message) -ScriptName $ScriptName -LogLevel "ERROR"
            }
            # --- SSL Profiles ---
            $ScriptName = 'f5SSLProfiles'
            Write-Log -Message ("Processing F5 node for SSL profiles: {0}" -f $node) -ScriptName $ScriptName
            try {
                $f5Session = New-F5Session -LTMName $node -LTMCredentials $Credential -ErrorAction Stop -PassThru $true
                $sslProfiles = Get-F5SSLProfiles -Session $f5Session -NodeName $node
                if ($sslProfiles -and $sslProfiles.Count -gt 0) {
                    Update-F5SSLProfileDatabase -profiles $sslProfiles -TableName $SSLProfilesTable
                    Write-Log -Message ("Upserted {0} SSL profiles for node {1}" -f $sslProfiles.Count, $node) -ScriptName $ScriptName
                } else {
                    Write-Log -Message ("No SSL profiles found for node {0}" -f $node) -ScriptName $ScriptName -LogLevel "WARNING"
                }
                Disconnect-F5LTM -Session $f5Session | Out-Null
            } catch {
                Write-Log -Message ("ERROR collecting SSL profiles for node {0}: {1}" -f $node, $_.Exception.Message) -ScriptName $ScriptName -LogLevel "ERROR"
            }
            # --- Virtual Servers ---
            $ScriptName = 'f5VirtualServers'
            Write-Log -Message ("Processing F5 node for virtual servers: {0}" -f $node) -ScriptName $ScriptName
            try {
                $f5Session = New-F5Session -LTMName $node -LTMCredentials $Credential -ErrorAction Stop -PassThru $true
                $virtualServers = Get-F5VirtualServers -Session $f5Session -NodeName $node
                if ($virtualServers -and $virtualServers.Count -gt 0) {
                    Update-F5VirtualServerDatabase -virtualServers $virtualServers -TableName $VirtualServersTable
                    Write-Log -Message ("Upserted {0} virtual servers for node {1}" -f $virtualServers.Count, $node) -ScriptName $ScriptName
                } else {
                    Write-Log -Message ("No virtual servers found for node {0}" -f $node) -ScriptName $ScriptName -LogLevel "WARNING"
                }
                Disconnect-F5LTM -Session $f5Session | Out-Null
            } catch {
                Write-Log -Message ("ERROR collecting virtual servers for node {0}: {1}" -f $node, $_.Exception.Message) -ScriptName $ScriptName -LogLevel "ERROR"
            }
        }
    }
    Write-Log -Message "F5 inventory collection script completed successfully" -ScriptName 'f5Inventory' -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -ScriptName 'f5Inventory' -LogLevel "ERROR"
    Write-Log -Message "F5 inventory collection script failed with errors" -ScriptName 'f5Inventory' -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ScriptName 'f5Inventory' -LogLevel "INFO"
}

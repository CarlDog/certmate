# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "certsIIS" #Also used for $ScriptName
$ScriptName = $Table # Name for logging purposes
$LogTable = "collectionLogs"
$ErrorActionPreference = 'Continue'

# =====================
# IIS Certificate Collection Parameters
# =====================
$StoreLocations = @("LocalMachine")
$StoreNames = @("WebHosting", "My") # Common IIS stores
# Filter certificates by subject and thumbprint
$ignoreCertificates = @() # Ignore certificate containing these filters
$ignoreThumbprints = @() # Ignore certificates matching these thumbprints 
$filterScript = { $_.Subject -notin $ignoreCertificates -and $_.Thumbprint -notin $ignoreThumbprints }

# =====================
# Machine Name Filter Settings
# =====================
$allowedPrefixes = @('CIR', 'WAU', 'UAT', 'INTG', 'TST')
$requiredSubstrings = @('IIS', 'SQL', 'SERVICER')
$excludedSubstrings = @('OLD', 'IGNORE', 'TEST')
$MachineNameFilter = {
    param($machineRow)
    $prefix = ($machineRow.MachineName.ToString()).Substring(0,3).ToUpper()
    $hasRequired = ($allowedPrefixes -contains $prefix) -and ($requiredSubstrings | Where-Object { $machineRow.MachineName -match $_ })
    $hasExcluded = $excludedSubstrings | Where-Object { $machineRow.MachineName -match $_ }
    return $hasRequired -and (-not $hasExcluded)
}

#region Templates
$CERTIFICATE_OBJECT_TEMPLATE = {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate,
        [string]$machineName,
        [string]$storeLocation,
        [string]$storeName,
        [bool]$isArchived
    )
    [pscustomobject]@{
        MachineName   = $machineName
        StoreLocation = $storeLocation
        StoreName     = $storeName
        Subject       = $certificate.Subject
        Issuer        = $certificate.Issuer
        Thumbprint    = $certificate.Thumbprint
        ValidFrom     = $certificate.NotBefore
        ValidTo       = $certificate.NotAfter
        IsArchived    = $isArchived
    }
}
#endregion

#region Functions
function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] $Message"
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

function Get-MachineList {
    try {
        $query = @"
SELECT * FROM [machineList] WHERE [IIS_Installed] = 1 AND [WinRM_Enabled] = 1
"@
        $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
        return $results
    } catch {
        Write-Log -Message ("Failed to retrieve machine list: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
        return @()
    }
}

# =====================
# Load archived thumbprints from certsRepo
# =====================
function Get-ArchivedThumbprints {
    $query = "SELECT Thumbprint FROM certsRepo WHERE IsArchived = 1"
    $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
    return $results | ForEach-Object { $_.Thumbprint }
}

function Get-RemoteIISCertificates {
    param (
        [string]$machineName,
        [array]$storeLocations,
        [array]$storeNames,
        [scriptblock]$filterScript,
        [array]$archivedThumbprints
    )
    $certificates = @()
    foreach ($storeLocation in $storeLocations) {
        foreach ($storeName in $storeNames) {
            try {
                $remoteCerts = Invoke-Command -ComputerName $machineName -ScriptBlock {
                    param($storeLocation, $storeName)
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, [System.Security.Cryptography.X509Certificates.StoreLocation]::$storeLocation)
                    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
                    $certs = $store.Certificates
                    $store.Close()
                    return $certs
                } -ArgumentList $storeLocation, $storeName -ErrorAction Stop
                foreach ($cert in $remoteCerts) {
                    if (& $filterScript $cert) {
                        $isArchived = $archivedThumbprints -contains $cert.Thumbprint
                        $certificates += & $CERTIFICATE_OBJECT_TEMPLATE -certificate $cert -machineName $machineName -storeLocation $storeLocation -storeName $storeName -isArchived $isArchived
                    }
                }
            } catch {
                Write-Log -Message ("Failed to retrieve certificates from $machineName [$storeLocation\\$storeName]: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
            }
        }
    }
    return $certificates
}

function Update-CertificateDatabase {
    param (
        [array]$certificates
    )
    try {
        $mergeCount = 0
        foreach ($cert in $certificates) {
            if ([string]::IsNullOrEmpty($cert.Thumbprint)) {
                Write-Log -Message ("Skipping certificate with null or empty thumbprint. Machine: {0}" -f $cert.MachineName) -LogLevel "WARNING"
                continue
            }
            $certificateId = [guid]::NewGuid().ToString()
            $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            $escapedMachineName = $cert.MachineName.Replace("'", "''")
            $escapedStoreLocation = $cert.StoreLocation.Replace("'", "''")
            $escapedStoreName = $cert.StoreName.Replace("'", "''")
            $escapedSubject = $cert.Subject.Replace("'", "''")
            $escapedIssuer = $cert.Issuer.Replace("'", "''")
            $escapedThumbprint = $cert.Thumbprint.Replace("'", "''")
            $validFromStr = $cert.ValidFrom.ToString('yyyy-MM-dd HH:mm:ss')
            $validToStr = $cert.ValidTo.ToString('yyyy-MM-dd HH:mm:ss')
            $isArchivedBit = if ($cert.IsArchived) { "1" } else { "0" }
            $escapedNotes = if ($null -ne $cert.Notes) { $cert.Notes.Replace("'", "''") } else { "" }
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedMachineName' AS [MachineName],
    N'$escapedThumbprint' AS [Thumbprint]
) AS Source
ON Target.[MachineName] = Source.[MachineName] AND Target.[Thumbprint] = Source.[Thumbprint]
WHEN MATCHED THEN
    UPDATE SET
        [StoreLocation] = N'$escapedStoreLocation',
        [StoreName] = N'$escapedStoreName',
        [Subject] = N'$escapedSubject',
        [Issuer] = N'$escapedIssuer',
        [ValidFrom] = '$validFromStr',
        [ValidTo] = '$validToStr',
        [IsArchived] = $isArchivedBit,
        [DateAdded] = '$dateAdded',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([CertificateId], [DateAdded], [MachineName], [StoreLocation], [StoreName], [Subject], [Issuer], [Thumbprint], [ValidFrom], [ValidTo], [IsArchived], [Notes])
    VALUES ('$certificateId', '$dateAdded', N'$escapedMachineName', N'$escapedStoreLocation', N'$escapedStoreName', N'$escapedSubject', N'$escapedIssuer', N'$escapedThumbprint', '$validFromStr', '$validToStr', $isArchivedBit, NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $mergeCount++
        }
        Write-Log -Message ("Successfully upserted {0} certificates into the database." -f $mergeCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update certificate database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

# =====================
# WinRM/Port Check Functions
# =====================
function Test-WinRMPort {
    param([string]$ComputerName = 'localhost', [int]$Port = 5985)
    try {
        $tcp = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
        return $tcp.TcpTestSucceeded
    } catch {
        return $false
    }
}

function Test-WinRMEnabled {
    param([string]$ComputerName)
    try {
        Test-WSMan -ComputerName $ComputerName -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}
#endregion

#region ScriptMain
try {
    Write-Log -Message ("Starting IIS certificate collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    # Preliminary check: Is WinRM port open on localhost?
    if (-not (Test-WinRMPort -ComputerName 'localhost' -Port 5985)) {
        Write-Log -Message ("WinRM port 5985 is not open on localhost. Exiting script.") -LogLevel "ERROR"
        throw "WinRM port 5985 is not open on localhost."
    }
    $archivedThumbprints = Get-ArchivedThumbprints
    $machineNames = Get-MachineList
    $filteredMachines = $machineNames | Where-Object { & $MachineNameFilter $_ }
    if ($filteredMachines -and $filteredMachines.Count -gt 0) {
        Write-Log -Message ("Found {0} machines to scan for IIS certificates" -f $filteredMachines.Count) -LogLevel "INFO"
        $allCertificates = @()
        foreach ($machine in $filteredMachines) {
            $machineName = $machine.MachineName.ToString()
            if (-not (Test-WinRMEnabled -ComputerName $machineName)) {
                Write-Log -Message ("Skipping $machineName because WinRM is not enabled") -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Scanning IIS certificate stores on {0}" -f $machineName) -LogLevel "INFO"
            $certs = Get-RemoteIISCertificates -machineName $machineName -storeLocations $StoreLocations -storeNames $StoreNames -filterScript $filterScript -archivedThumbprints $archivedThumbprints
            if ($certs) {
                $allCertificates += $certs
            }
        }
        if ($allCertificates.Count -gt 0) {
            Write-Log -Message ("Updating SQL database with {0} IIS certificates" -f $allCertificates.Count) -LogLevel "INFO"
            Update-CertificateDatabase -certificates $allCertificates
        } else {
            Write-Log -Message ("No IIS certificates found to insert into the database") -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("No machines found in machineList table matching allowed prefixes.") -LogLevel "WARNING"
    }
    Write-Log -Message ("IIS certificate collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("IIS certificate collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

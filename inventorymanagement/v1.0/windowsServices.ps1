# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "windowsServices"
$ScriptName = $Table
$LogTable = "collectionLogs"
$ErrorActionPreference = 'Continue'

# =====================
# Machine Name Filter Settings
# =====================
$allowedPrefixes = @('CIR', 'WAU', 'UAT', 'INTG', 'TST')
$requiredSubstrings = @('IIS', 'SQL', 'SERVICER')
$excludedSubstrings = @('OLD', 'IGNORE', 'TEST')
$MachineNameFilter = {
    param($machineRow)
    $prefix = ([string]$machineRow.MachineName).Substring(0,3).ToUpper()
    $hasRequired = ($allowedPrefixes -contains $prefix) -and ($requiredSubstrings | Where-Object { $machineRow.MachineName -match $_ })
    $hasExcluded = $excludedSubstrings | Where-Object { $machineRow.MachineName -match $_ }
    return $hasRequired -and (-not $hasExcluded)
}

#region Functions
function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output ("[{0}] {1}" -f $timestamp, $Message)
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
SELECT * FROM [machineList] WHERE [AD_Enabled] = 1 AND [WinRM_Enabled] = 1
"@
        $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
        return $results
    } catch {
        Write-Log -Message ("Failed to retrieve machine list: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
        return @()
    }
}

function Get-RemoteWindowsServices {
    param (
        [string]$machineName
    )
    $services = @()
    try {
        $remoteServices = Invoke-Command -ComputerName $machineName -ScriptBlock {
            function Get-ServiceRecovery {
                param($serviceName)
                $scOutput = sc.exe qfailure $serviceName 2>&1
                if ($LASTEXITCODE -ne 0) { return $null }
                $lines = $scOutput | Where-Object { $_ -match ':' }
                $recovery = @{}
                foreach ($line in $lines) {
                    $parts = $line -split ':', 2
                    if ($parts.Length -eq 2) {
                        $key = $parts[0].Trim()
                        $val = $parts[1].Trim()
                        $recovery[$key] = $val
                    }
                }
                return ($recovery | ConvertTo-Json -Compress)
            }
            Get-WmiObject -Class Win32_Service | Select-Object `
                Name, DisplayName, State, StartMode, StartName, Description, Dependencies | ForEach-Object {
                $recoveryJson = Get-ServiceRecovery $_.Name
                [PSCustomObject]@{
                    MachineName  = $using:machineName
                    ServiceName  = $_.Name
                    DisplayName  = $_.DisplayName
                    Status       = $_.State
                    StartType    = $_.StartMode
                    LogOnAs      = $_.StartName
                    Description  = $_.Description
                    Dependencies = ($_.Dependencies -join ',')
                    Recovery     = $recoveryJson
                }
            }
        } -ErrorAction Stop
        $services += $remoteServices
    } catch {
        Write-Log -Message ("Failed to retrieve services from {0}: {1}" -f $machineName, $error[0].Exception.Message) -LogLevel "ERROR"
    }
    return $services
}

function Update-WindowsServicesDatabase {
    param (
        [array]$services
    )
    try {
        $mergeCount = 0
        foreach ($svc in $services) {
            if ($null -eq $svc) { continue }
            $escapedMachineName = if ($svc.PSObject.Properties['MachineName'] -and $null -ne $svc.MachineName) { $svc.MachineName.Replace("'", "''") } else { "" }
            $escapedServiceName = if ($svc.PSObject.Properties['ServiceName'] -and $null -ne $svc.ServiceName) { $svc.ServiceName.Replace("'", "''") } else { "" }
            $escapedDisplayName = if ($svc.PSObject.Properties['DisplayName'] -and $null -ne $svc.DisplayName) { $svc.DisplayName.Replace("'", "''") } else { "" }
            $escapedStatus = if ($svc.PSObject.Properties['Status'] -and $null -ne $svc.Status) { $svc.Status.Replace("'", "''") } else { "" }
            $escapedStartType = if ($svc.PSObject.Properties['StartType'] -and $null -ne $svc.StartType) { $svc.StartType.Replace("'", "''") } else { "" }
            $escapedLogOnAs = if ($svc.PSObject.Properties['LogOnAs'] -and $null -ne $svc.LogOnAs) { $svc.LogOnAs.Replace("'", "''") } else { "" }
            $escapedDescription = if ($svc.PSObject.Properties['Description'] -and $null -ne $svc.Description) { $svc.Description.Replace("'", "''") } else { "" }
            $escapedDependencies = if ($svc.PSObject.Properties['Dependencies'] -and $null -ne $svc.Dependencies) { $svc.Dependencies.Replace("'", "''") } else { "" }
            $escapedRecovery = if ($svc.PSObject.Properties['Recovery'] -and $null -ne $svc.Recovery) { $svc.Recovery.Replace("'", "''") } else { "" }
            $escapedNotes = if ($svc.PSObject.Properties['Notes'] -and $null -ne $svc.Notes) { $svc.Notes.Replace("'", "''") } else { "" }
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedMachineName' AS [MachineName],
    N'$escapedServiceName' AS [ServiceName]
) AS Source
ON Target.[MachineName] = Source.[MachineName] AND Target.[ServiceName] = Source.[ServiceName]
WHEN MATCHED THEN
    UPDATE SET
        [DisplayName] = N'$escapedDisplayName',
        [Status] = N'$escapedStatus',
        [StartType] = N'$escapedStartType',
        [LogOnAs] = N'$escapedLogOnAs',
        [Description] = N'$escapedDescription',
        [Dependencies] = N'$escapedDependencies',
        [Recovery] = N'$escapedRecovery',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([MachineName], [ServiceName], [DisplayName], [Status], [StartType], [LogOnAs], [Description], [Dependencies], [Recovery], [Notes])
    VALUES (N'$escapedMachineName', N'$escapedServiceName', N'$escapedDisplayName', N'$escapedStatus', N'$escapedStartType', N'$escapedLogOnAs', N'$escapedDescription', N'$escapedDependencies', N'$escapedRecovery', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $mergeCount++
        }
        Write-Log -Message ("Successfully upserted {0} services into the database." -f $mergeCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to upsert services database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
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
    Write-Log -Message ("Starting Windows services collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    # Preliminary check: Is WinRM port open on localhost?
    if (-not (Test-WinRMPort -ComputerName 'localhost' -Port 5985)) {
        Write-Log -Message ("WinRM port 5985 is not open on localhost. Exiting script.") -LogLevel "ERROR"
        throw "WinRM port 5985 is not open on localhost."
    }
    $machineNames = Get-MachineList
    $filteredMachines = $machineNames | Where-Object { & $MachineNameFilter $_ }
    if ($filteredMachines -and $filteredMachines.Count -gt 0) {
        Write-Log -Message ("Found {0} machines to scan for services" -f $filteredMachines.Count) -LogLevel "INFO"
        $allServices = @()
        foreach ($machine in $filteredMachines) {
            $machineName = $machine.MachineName.ToString()
            if (-not (Test-WinRMEnabled -ComputerName $machineName)) {
                Write-Log -Message ("Skipping $machineName because WinRM is not enabled") -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Collecting services on {0}" -f $machineName) -LogLevel "INFO"
            $services = Get-RemoteWindowsServices -machineName $machineName
            if ($services) {
                $allServices += $services
            }
        }
        if ($allServices.Count -gt 0) {
            Write-Log -Message ("Updating SQL database with {0} services" -f $allServices.Count) -LogLevel "INFO"
            Update-WindowsServicesDatabase -services $allServices
        } else {
            Write-Log -Message ("No services found to insert into the database") -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("No machines found in machineList table matching filter.") -LogLevel "WARNING"
    }
    Write-Log -Message ("Windows services collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("Windows services collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

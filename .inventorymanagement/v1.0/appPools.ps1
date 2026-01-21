# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "appPools"
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
SELECT * FROM [machineList] WHERE [IIS_Installed] = 1 AND [WinRM_Enabled] = 1
"@
        $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
        return $results
    } catch {
        Write-Log -Message ("Failed to retrieve machine list: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
        return @()
    }
}

function Get-RemoteAppPools {
    param (
        [string]$machineName
    )
    $appPools = @()
    try {
        $remoteAppPools = Invoke-Command -ComputerName $machineName -ScriptBlock {
            Import-Module WebAdministration
            Get-ChildItem IIS:\AppPools | ForEach-Object {
                [PSCustomObject]@{
                    MachineName      = $using:machineName
                    Name             = $_.Name
                    State            = $_.State
                    PipelineMode     = $_.ManagedPipelineMode
                    RuntimeVersion   = $_.ManagedRuntimeVersion
                    IdentityType     = $_.ProcessModel.IdentityType
                    UserName         = $_.ProcessModel.UserName
                    StartMode        = $_.StartMode
                    AutoStart        = $_.AutoStart
                    Enable32BitAppOnWin64 = $_.Enable32BitAppOnWin64
                    QueueLength      = $_.QueueLength
                    Recycling        = ($_.Recycling | ConvertTo-Json -Compress)
                    Failure          = ($_.Failure | ConvertTo-Json -Compress)
                    CPU              = ($_.CPU | ConvertTo-Json -Compress)
                    ProcessModel     = ($_.ProcessModel | ConvertTo-Json -Compress)
                    Notes            = $_.Notes
                }
            }
        } -ErrorAction Stop
        $appPools += $remoteAppPools
    } catch {
        Write-Log -Message ("Failed to retrieve app pools from {0}: {1}" -f $machineName, $error[0].Exception.Message) -LogLevel "ERROR"
    }
    return $appPools
}

function Update-AppPoolsDatabase {
    param (
        [array]$appPools
    )
    try {
        foreach ($pool in $appPools) {
            $escapedMachineName = if ($null -ne $pool.MachineName) { $pool.MachineName.Replace("'", "''") } else { "" }
            $escapedName = if ($null -ne $pool.Name) { $pool.Name.Replace("'", "''") } else { "" }
            $escapedState = if ($null -ne $pool.State) { $pool.State.Replace("'", "''") } else { "" }
            $escapedPipelineMode = if ($null -ne $pool.PipelineMode) { $pool.PipelineMode.Replace("'", "''") } else { "" }
            $escapedRuntimeVersion = if ($null -ne $pool.RuntimeVersion) { $pool.RuntimeVersion.Replace("'", "''") } else { "" }
            $escapedIdentityType = if ($null -ne $pool.IdentityType) { $pool.IdentityType.Replace("'", "''") } else { "" }
            $escapedUserName = if ($null -ne $pool.UserName) { $pool.UserName.Replace("'", "''") } else { "" }
            $escapedStartMode = if ($null -ne $pool.StartMode) { $pool.StartMode.Replace("'", "''") } else { "" }
            $escapedAutoStart = if ($null -ne $pool.AutoStart) { $pool.AutoStart.ToString().Replace("'", "''") } else { "" }
            $escapedEnable32Bit = if ($null -ne $pool.Enable32BitAppOnWin64) { $pool.Enable32BitAppOnWin64.ToString().Replace("'", "''") } else { "" }
            $escapedQueueLength = if ($null -ne $pool.QueueLength) { $pool.QueueLength.ToString().Replace("'", "''") } else { "" }
            $escapedRecycling = if ($null -ne $pool.Recycling) { $pool.Recycling.Replace("'", "''") } else { "" }
            $escapedFailure = if ($null -ne $pool.Failure) { $pool.Failure.Replace("'", "''") } else { "" }
            $escapedCPU = if ($null -ne $pool.CPU) { $pool.CPU.Replace("'", "''") } else { "" }
            $escapedProcessModel = if ($null -ne $pool.ProcessModel) { $pool.ProcessModel.Replace("'", "''") } else { "" }
            $escapedNotes = if ($null -ne $pool.Notes) { $pool.Notes.Replace("'", "''") } else { "" }
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedMachineName' AS [MachineName],
    N'$escapedName' AS [Name]
) AS Source
ON Target.[MachineName] = Source.[MachineName] AND Target.[Name] = Source.[Name]
WHEN MATCHED THEN
    UPDATE SET
        [State] = N'$escapedState',
        [PipelineMode] = N'$escapedPipelineMode',
        [RuntimeVersion] = N'$escapedRuntimeVersion',
        [IdentityType] = N'$escapedIdentityType',
        [UserName] = N'$escapedUserName',
        [StartMode] = N'$escapedStartMode',
        [AutoStart] = N'$escapedAutoStart',
        [Enable32BitAppOnWin64] = N'$escapedEnable32Bit',
        [QueueLength] = N'$escapedQueueLength',
        [Recycling] = N'$escapedRecycling',
        [Failure] = N'$escapedFailure',
        [CPU] = N'$escapedCPU',
        [ProcessModel] = N'$escapedProcessModel',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([MachineName], [Name], [State], [PipelineMode], [RuntimeVersion], [IdentityType], [UserName], [StartMode], [AutoStart], [Enable32BitAppOnWin64], [QueueLength], [Recycling], [Failure], [CPU], [ProcessModel], [Notes])
    VALUES (N'$escapedMachineName', N'$escapedName', N'$escapedState', N'$escapedPipelineMode', N'$escapedRuntimeVersion', N'$escapedIdentityType', N'$escapedUserName', N'$escapedStartMode', N'$escapedAutoStart', N'$escapedEnable32Bit', N'$escapedQueueLength', N'$escapedRecycling', N'$escapedFailure', N'$escapedCPU', N'$escapedProcessModel', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
        }
        Write-Log -Message ("Successfully upserted {0} app pools into the database." -f $appPools.Count) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to upsert app pools database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
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
    Write-Log -Message ("Starting IIS app pool collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    # Preliminary check: Is WinRM port open on localhost?
    if (-not (Test-WinRMPort -ComputerName 'localhost' -Port 5985)) {
        Write-Log -Message ("WinRM port 5985 is not open on localhost. Exiting script.") -LogLevel "ERROR"
        throw "WinRM port 5985 is not open on localhost."
    }
    $machineNames = Get-MachineList
    $filteredMachines = $machineNames | Where-Object { & $MachineNameFilter $_ }
    if ($filteredMachines -and $filteredMachines.Count -gt 0) {
        Write-Log -Message ("Found {0} machines to scan for app pools" -f $filteredMachines.Count) -LogLevel "INFO"
        $allAppPools = @()
        foreach ($machine in $filteredMachines) {
            $machineName = $machine.MachineName.ToString()
            if (-not (Test-WinRMEnabled -ComputerName $machineName)) {
                Write-Log -Message ("Skipping $machineName because WinRM is not enabled") -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Collecting app pools on {0}" -f $machineName) -LogLevel "INFO"
            $appPools = Get-RemoteAppPools -machineName $machineName
            if ($appPools) {
                $allAppPools += $appPools
            }
        }
        if ($allAppPools.Count -gt 0) {
            Write-Log -Message ("Updating SQL database with {0} app pools" -f $allAppPools.Count) -LogLevel "INFO"
            Update-AppPoolsDatabase -appPools $allAppPools
        } else {
            Write-Log -Message ("No app pools found to insert into the database") -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("No machines found in machineList table matching filter.") -LogLevel "WARNING"
    }
    Write-Log -Message ("IIS app pool collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("IIS app pool collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

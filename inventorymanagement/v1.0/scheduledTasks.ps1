# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "scheduledTasks" #Also used for $ScriptName
$ScriptName = $Table # Name for logging purposes
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

function Get-RemoteScheduledTasks {
    param (
        [string]$machineName
    )
    $tasks = @()
    try {
        $remoteTasks = Invoke-Command -ComputerName $machineName -ScriptBlock {
            function Get-TriggerSummary {
                param($trigger)
                switch ($trigger.TriggerType) {
                    'Time' { return "Once at {0}" -f $trigger.StartBoundary }
                    'Daily' { return "Daily at {0}" -f $trigger.StartBoundary }
                    'Weekly' { return "Weekly on {0} at {1}" -f ($trigger.DaysOfWeek -join ','), $trigger.StartBoundary }
                    'AtLogon' { return "At logon" }
                    'AtStartup' { return "At startup" }
                    'Monthly' { return "Monthly on {0} at {1}" -f ($trigger.DaysOfMonth -join ','), $trigger.StartBoundary }
                    default { return $trigger.TriggerType }
                }
            }
            Get-ScheduledTask | Select-Object TaskName, TaskPath, State, Author, Description, Actions, Triggers, Settings | ForEach-Object {
                $triggerSummaries = @()
                foreach ($trigger in $_.Triggers) {
                    $triggerSummaries += Get-TriggerSummary $trigger
                }
                [PSCustomObject]@{
                    MachineName  = $using:machineName
                    TaskName     = $_.TaskName
                    TaskPath     = $_.TaskPath
                    State        = $_.State
                    Author       = $_.Author
                    Description  = $_.Description
                    Actions      = ($_.Actions | ConvertTo-Json -Compress)
                    Triggers     = ($_.Triggers | ConvertTo-Json -Compress)
                    Settings     = ($_.Settings | ConvertTo-Json -Compress)
                    TriggerSummary = ($triggerSummaries -join '; ')
                    Notes        = if ($_.Notes) { $_.Notes } else { $null }
                }
            }
        } -ErrorAction Stop
        $tasks += $remoteTasks
    } catch {
        Write-Log -Message ("Failed to retrieve scheduled tasks from {0}: {1}" -f $machineName, $error[0].Exception.Message) -LogLevel "ERROR"
    }
    return $tasks
}

function Update-ScheduledTasksDatabase {
    param (
        [array]$tasks
    )
    try {
        foreach ($task in $tasks) {
            if ($null -eq $task) { continue }
            function ToSqlString($val) {
                if ($null -eq $val) { return "" }
                $str = $val -as [string]
                if ($null -eq $str) { return "" }
                return $str.Replace("'", "''")
            }
            $escapedMachineName = if ($task.PSObject.Properties['MachineName'] -and $null -ne $task.MachineName) { ToSqlString $task.MachineName } else { "" }
            $escapedTaskName = if ($task.PSObject.Properties['TaskName'] -and $null -ne $task.TaskName) { ToSqlString $task.TaskName } else { "" }
            $escapedTaskPath = if ($task.PSObject.Properties['TaskPath'] -and $null -ne $task.TaskPath) { ToSqlString $task.TaskPath } else { "" }
            $escapedState = if ($task.PSObject.Properties['State'] -and $null -ne $task.State) { ToSqlString $task.State } else { "" }
            $escapedAuthor = if ($task.PSObject.Properties['Author'] -and $null -ne $task.Author) { ToSqlString $task.Author } else { "" }
            $escapedDescription = if ($task.PSObject.Properties['Description'] -and $null -ne $task.Description) { ToSqlString $task.Description } else { "" }
            $escapedActions = if ($task.PSObject.Properties['Actions'] -and $null -ne $task.Actions) { ToSqlString $task.Actions } else { "" }
            $escapedTriggers = if ($task.PSObject.Properties['Triggers'] -and $null -ne $task.Triggers) { ToSqlString $task.Triggers } else { "" }
            $escapedSettings = if ($task.PSObject.Properties['Settings'] -and $null -ne $task.Settings) { ToSqlString $task.Settings } else { "" }
            $escapedTriggerSummary = if ($task.PSObject.Properties['TriggerSummary'] -and $null -ne $task.TriggerSummary) { ToSqlString $task.TriggerSummary } else { "" }
            $escapedNotes = if ($task.PSObject.Properties['Notes'] -and $null -ne $task.Notes) { ToSqlString $task.Notes } else { "" }
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedMachineName' AS [MachineName],
    N'$escapedTaskName' AS [TaskName],
    N'$escapedTaskPath' AS [TaskPath]
) AS Source
ON Target.[MachineName] = Source.[MachineName] AND Target.[TaskName] = Source.[TaskName] AND Target.[TaskPath] = Source.[TaskPath]
WHEN MATCHED THEN
    UPDATE SET
        [State] = N'$escapedState',
        [Author] = N'$escapedAuthor',
        [Description] = N'$escapedDescription',
        [Actions] = N'$escapedActions',
        [Triggers] = N'$escapedTriggers',
        [Settings] = N'$escapedSettings',
        [TriggerSummary] = N'$escapedTriggerSummary',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([MachineName], [TaskName], [TaskPath], [State], [Author], [Description], [Actions], [Triggers], [Settings], [TriggerSummary], [Notes])
    VALUES (N'$escapedMachineName', N'$escapedTaskName', N'$escapedTaskPath', N'$escapedState', N'$escapedAuthor', N'$escapedDescription', N'$escapedActions', N'$escapedTriggers', N'$escapedSettings', N'$escapedTriggerSummary', NULLIF(N'$escapedNotes', ''));
"@
            Write-Log -Message ("DEBUG: About to run SQL merge query for scheduled task: MachineName={0}, TaskName={1}, TaskPath={2}" -f $escapedMachineName, $escapedTaskName, $escapedTaskPath) -LogLevel "DEBUG"
            Write-Log -Message ("DEBUG: SQL Query: {0}" -f $mergeQuery) -LogLevel "DEBUG"
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
        }
        Write-Log -Message ("Successfully upserted {0} scheduled tasks into the database." -f $tasks.Count) -LogLevel "INFO"
    } catch {
        $errMsg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message }
                  elseif ($_ -ne $null) { $_ | Out-String }
                  elseif ($error -and $error[0]) { $error[0] | Out-String }
                  else { 'Unknown error (no exception or error object available)' }
        Write-Log -Message ("DEBUG: Failed task object: {0}" -f ($task | ConvertTo-Json -Compress)) -LogLevel "ERROR"
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $errMsg, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to upsert scheduled tasks database. Error: {0}" -f $errMsg) -LogLevel "ERROR"
        Write-Error ("Update-ScheduledTasksDatabase failed: {0}" -f $errMsg)
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
    Write-Log -Message ("Starting scheduled tasks collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    # Preliminary check: Is WinRM port open on localhost?
    if (-not (Test-WinRMPort -ComputerName 'localhost' -Port 5985)) {
        Write-Log -Message ("WinRM port 5985 is not open on localhost. Exiting script.") -LogLevel "ERROR"
        throw "WinRM port 5985 is not open on localhost."
    }
    $machineNames = Get-MachineList
    $filteredMachines = $machineNames | Where-Object { & $MachineNameFilter $_ }
    if ($filteredMachines -and $filteredMachines.Count -gt 0) {
        Write-Log -Message ("Found {0} machines to scan for scheduled tasks" -f $filteredMachines.Count) -LogLevel "INFO"
        $allTasks = @()
        foreach ($machine in $filteredMachines) {
            $machineName = $machine.MachineName.ToString()
            if (-not (Test-WinRMEnabled -ComputerName $machineName)) {
                Write-Log -Message ("Skipping $machineName because WinRM is not enabled") -LogLevel "WARNING"
                continue
            }
            Write-Log -Message ("Collecting scheduled tasks on {0}" -f $machineName) -LogLevel "INFO"
            $tasks = Get-RemoteScheduledTasks -machineName $machineName
            if ($tasks) {
                $allTasks += $tasks
            }
        }
        if ($allTasks.Count -gt 0) {
            Write-Log -Message ("Updating SQL database with {0} scheduled tasks" -f $allTasks.Count) -LogLevel "INFO"
            Update-ScheduledTasksDatabase -tasks $allTasks
        } else {
            Write-Log -Message ("No scheduled tasks found to insert into the database") -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("No machines found in machineList table matching filter.") -LogLevel "WARNING"
    }
    Write-Log -Message ("Scheduled tasks collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("Scheduled tasks collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "iisWebSites"
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
    $prefix = ($machineRow.MachineName.ToString()).Substring(0,3).ToUpper()
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

function Get-RemoteIisSites {
    param (
        [string]$machineName
    )
    $sites = @()
    try {
        $remoteSites = Invoke-Command -ComputerName $machineName -ScriptBlock {
            Import-Module WebAdministration
            Get-ChildItem IIS:\Sites | ForEach-Object {
                [PSCustomObject]@{
                    MachineName    = $using:machineName
                    Name           = $_.Name
                    SiteId         = $_.Id
                    State          = $_.State
                    PhysicalPath   = $_.PhysicalPath
                    Bindings       = ($_.Bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ';'
                    ApplicationPool= $_.ApplicationPool
                    Limits         = ($_.Limits | ConvertTo-Json -Compress)
                    LogFile        = ($_.LogFile | ConvertTo-Json -Compress)
                    Applications   = ($_.Applications | ForEach-Object {
                        [PSCustomObject]@{
                            Path = $_.Path
                            ApplicationPool = $_.ApplicationPoolName
                            VirtualDirectories = ($_.VirtualDirectories | ForEach-Object {
                                [PSCustomObject]@{
                                    Path = $_.Path
                                    PhysicalPath = $_.PhysicalPath
                                }
                            })
                        }
                    } | ConvertTo-Json -Compress)
                    Notes          = $_.Notes
                }
            }
        } -ErrorAction Stop
        $sites += $remoteSites
    } catch {
        Write-Log -Message ("Failed to retrieve IIS sites from {0}: {1}" -f $machineName, $error[0].Exception.Message) -LogLevel "ERROR"
    }
    return $sites
}

function Update-IisSitesDatabase {
    param (
        [array]$sites
    )
    try {
        $mergeCount = 0
        foreach ($site in $sites) {
            $escapedMachineName = if ($null -ne $site.MachineName) { ([string]$site.MachineName).Replace("'", "''") } else { "" }
            $escapedName = if ($null -ne $site.Name) { ([string]$site.Name).Replace("'", "''") } else { "" }
            $escapedSiteId = if ($null -ne $site.SiteId) { ([string]$site.SiteId).Replace("'", "''") } else { "" }
            $escapedState = if ($null -ne $site.State) { ([string]$site.State).Replace("'", "''") } else { "" }
            $escapedPhysicalPath = if ($null -ne $site.PhysicalPath) { ([string]$site.PhysicalPath).Replace("'", "''") } else { "" }
            $escapedBindings = if ($null -ne $site.Bindings) { ([string]$site.Bindings).Replace("'", "''") } else { "" }
            $escapedApplicationPool = if ($null -ne $site.ApplicationPool) { ([string]$site.ApplicationPool).Replace("'", "''") } else { "" }
            $escapedLimits = if ($null -ne $site.Limits) { ([string]$site.Limits).Replace("'", "''") } else { "" }
            $escapedLogFile = if ($null -ne $site.LogFile) { ([string]$site.LogFile).Replace("'", "''") } else { "" }
            $escapedApplications = if ($null -ne $site.Applications) { ([string]$site.Applications).Replace("'", "''") } else { "" }
            $escapedNotes = if ($null -ne $site.Notes) { $site.Notes.Replace("'", "''") } else { "" }
            $mergeQuery = @"
MERGE INTO [$Table] AS Target
USING (SELECT
    N'$escapedMachineName' AS [MachineName],
    N'$escapedName' AS [Name],
    N'$escapedSiteId' AS [SiteId]
) AS Source
ON Target.[MachineName] = Source.[MachineName] AND Target.[SiteId] = Source.[SiteId]
WHEN MATCHED THEN
    UPDATE SET
        [State] = N'$escapedState',
        [PhysicalPath] = N'$escapedPhysicalPath',
        [Bindings] = N'$escapedBindings',
        [ApplicationPool] = N'$escapedApplicationPool',
        [Limits] = N'$escapedLimits',
        [LogFile] = N'$escapedLogFile',
        [Applications] = N'$escapedApplications',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([MachineName], [Name], [SiteId], [State], [PhysicalPath], [Bindings], [ApplicationPool], [Limits], [LogFile], [Applications], [Notes])
    VALUES (N'$escapedMachineName', N'$escapedName', N'$escapedSiteId', N'$escapedState', N'$escapedPhysicalPath', N'$escapedBindings', N'$escapedApplicationPool', N'$escapedLimits', N'$escapedLogFile', N'$escapedApplications', NULLIF(N'$escapedNotes', ''));
"@
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery
            $mergeCount++
        }
        Write-Log -Message ("Successfully upserted {0} IIS sites into the database." -f $mergeCount) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to upsert IIS sites database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}
#endregion

#region ScriptMain
try {
    Write-Log -Message ("Starting IIS site collection script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    $machineNames = Get-MachineList
    $filteredMachines = $machineNames | Where-Object { & $MachineNameFilter $_ }
    if ($filteredMachines -and $filteredMachines.Count -gt 0) {
        Write-Log -Message ("Found {0} machines to scan for IIS sites" -f $filteredMachines.Count) -LogLevel "INFO"
        $allSites = @()
        foreach ($machine in $filteredMachines) {
            Write-Log -Message ("Collecting IIS sites on {0}" -f $machine.MachineName) -LogLevel "INFO"
            $sites = Get-RemoteIisSites -machineName $machine.MachineName
            if ($sites) {
                $allSites += $sites
            }
        }
        if ($allSites.Count -gt 0) {
            Write-Log -Message ("Updating SQL database with {0} IIS sites" -f $allSites.Count) -LogLevel "INFO"
            Update-IisSitesDatabase -sites $allSites
        } else {
            Write-Log -Message ("No IIS sites found to insert into the database") -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("No machines found in machineList table matching filter.") -LogLevel "WARNING"
    }
    Write-Log -Message ("IIS site collection script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("IIS site collection script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

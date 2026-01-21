# =====================
# Global Parameters & Variables
# =====================
#region Variables
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "machineList"
$ScriptName = $Table
$LogTable = "collectionLogs"
$ErrorActionPreference = 'Continue'
$ou = "OU=Servers,DC=us,DC=Cambridge"
$osFilter = @("Windows*")
$machineFilter = @()
$excludeFilter = @()
$enabledOnly = $true
#endregion

# =====================
# Construct the LDAP filter string
# =====================
$filter = "(&(objectClass=computer)"
$osFilter | ForEach-Object { $filter += "(operatingSystem=$_)" }
$machineFilter | ForEach-Object { $filter += "(name=$_)" }
$excludeFilter | ForEach-Object { $filter += "(!(name=$_))" }
if ($enabledOnly) { $filter += "(!(userAccountControl:1.2.840.113556.1.4.803:=2))" }
$filter += ")"

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

function ToSqlValue($val) {
    if ($null -eq $val -or $val -eq '') { return 'NULL' }
    if ($val -is [datetime]) { return "'" + $val.ToString('yyyy-MM-dd HH:mm:ss') + "'" }
    if ($val -is [string]) { return "'" + $val.Replace("'", "''") + "'" }
    return $val
}

function Test-IsAdminRemote {
    param([string]$ComputerName)
    try {
        $isAdmin = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal $currentUser
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } -ErrorAction Stop
        return $isAdmin -eq $true
    } catch {
        return $false
    }
}
#endregion

#region ScriptMain
try {
    Write-Log -Message ("Starting machine list script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
    if (-not (Test-WinRMPort -ComputerName 'localhost' -Port 5985)) {
        Write-Log -Message ("WinRM port 5985 is not open on localhost. Exiting script.") -LogLevel "ERROR"
        throw "WinRM port 5985 is not open on localhost."
    }
    try {
        Write-Log -Message ("Retrieving machines from Active Directory with filter: {0}" -f $filter) -LogLevel "INFO"
        $machines = Get-ADComputer -LDAPFilter $filter -SearchBase $ou -Property Name, OperatingSystem, Enabled, DistinguishedName, Description, DNSHostName |
            Select-Object @{Name='MachineName';Expression={$_.Name}}, OperatingSystem, Enabled, DistinguishedName, Description, DNSHostName
    } catch {
        Write-Log -Message ("Error retrieving machines from Active Directory: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
        exit 1
    }
    if ($machines) {
        Write-Log -Message ("Found {0} machines matching the filter criteria" -f $machines.Count) -LogLevel "INFO"
        foreach ($machine in $machines) {
            try {
                # Skip if MachineName is null or empty
                if ([string]::IsNullOrWhiteSpace($machine.MachineName)) {
                    Write-Log -Message ("Skipping machine with null or empty MachineName.") -LogLevel "WARNING"
                    continue
                }
                Write-Log -Message ("Processing machine: {0}" -f $machine.MachineName) -LogLevel "INFO"
                $winrmEnabled = Test-WinRMEnabled -ComputerName $machine.MachineName
                $winrmEnabledBit = if ($winrmEnabled) { 1 } else { 0 }
                $iisInstalledBit = $null
                $dotNetFrameworkVersions = $null
                $dotNetCoreVersions = $null
                $osVersion = $null
                $lastBootTime = $null
                $cpuCount = $null
                $totalMemoryGB = $null
                $isVirtual = $null
                $manufacturer = $null
                $model = $null
                $domain = $null
                $primaryRole = $null
                $servicePack = $null
                $diskFreeSpaceGB = $null
                $antivirusProduct = $null
                $lastSeen = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                $notes = $null
                $adEnabledBit = if ($machine.Enabled) { 1 } else { 0 }
                $environment = $null
                if ($machine.MachineName -match "^CIR|^WAU") {
                    $environment = "PROD"
                } elseif ($machine.MachineName -match "^UAT") {
                    $environment = "UAT"
                } elseif ($machine.MachineName -match "^GIL") {
                    $environment = "DR"
                } elseif ($machine.MachineName -match "^DEV") {
                    $environment = "DEV"
                } elseif ($machine.MachineName -match "^TST") {
                    $environment = "TEST"
                } elseif ($machine.MachineName -match "^INTG") {
                    $environment = "INTG"
                } else {
                    $environment = "UNKNOWN"
                }
                $ipAddress = $null
                if (-not [string]::IsNullOrEmpty($machine.DNSHostName)) {
                    try {
                        $resolvedIP = [System.Net.Dns]::GetHostAddresses($machine.DNSHostName) |
                                      Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                                      Select-Object -First 1 -ExpandProperty IPAddressToString
                        if ($resolvedIP) {
                            $ipAddress = $resolvedIP
                        }
                    } catch {}
                }
                $canRunElevated = $false
                if ($winrmEnabled) {
                    $canRunElevated = Test-IsAdminRemote -ComputerName $machine.MachineName
                    if (-not $canRunElevated) {
                        Write-Log -Message ("User is not an administrator on {0}. Skipping elevated scans." -f $machine.MachineName) -LogLevel "WARNING"
                    }
                }
                if ($winrmEnabled -and $canRunElevated) {
                    # IIS check
                    $iisInstalled = $false
                    try {
                        $iisResult = Invoke-Command -ComputerName $machine.MachineName -ScriptBlock { Get-WindowsFeature -Name Web-Server } -ErrorAction Stop
                        if ($iisResult -and $iisResult.Installed) { $iisInstalled = $true }
                    } catch {
                        Write-Log -Message ("Could not determine IIS status for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                    $iisInstalledBit = if ($iisInstalled) { 1 } else { 0 }
                    # .NET versions
                    try {
                        $dotNetResult = Invoke-Command -ComputerName $machine.MachineName -ScriptBlock {
                            $frameworkVersions = @()
                            $coreRuntimes = @()
                            $regPaths = @(
                                'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP',
                                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\NET Framework Setup\NDP'
                            )
                            foreach ($regPath in $regPaths) {
                                if (Test-Path $regPath) {
                                    Get-ChildItem $regPath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.GetValue('Version', $null) } | ForEach-Object {
                                        $ver = $_.GetValue('Version', $null)
                                        if ($ver -and ($ver -notin $frameworkVersions)) { $frameworkVersions += $ver }
                                    }
                                }
                            }
                            $dotnetExe = $null
                            $envPaths = $env:PATH -split ';'
                            foreach ($p in $envPaths) {
                                $candidate = Join-Path $p 'dotnet.exe'
                                if (Test-Path $candidate) { $dotnetExe = $candidate; break }
                            }
                            if ($dotnetExe) {
                                try {
                                    $coreRuntimes = & $dotnetExe --list-runtimes 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                                } catch {}
                            }
                            [PSCustomObject]@{
                                Framework = $frameworkVersions -join ', '
                                Core = $coreRuntimes -join '; '
                            }
                        } -ErrorAction Stop
                        if ($dotNetResult) {
                            $dotNetFrameworkVersions = $dotNetResult.Framework
                            $dotNetCoreVersions = $dotNetResult.Core
                        }
                    } catch {
                        Write-Log -Message ("Could not determine .NET versions for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                    # Disk info
                    try {
                        $allDisks = Invoke-Command -ComputerName $machine.MachineName -ScriptBlock {
                            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
                                $label = $_.DeviceID
                                $free = [math]::Round($_.FreeSpace / 1GB, 2)
                                "$label $free"
                            }
                        } -ErrorAction Stop
                        if ($allDisks) { $diskFreeSpaceGB = $allDisks -join ';' }
                    } catch {
                        Write-Log -Message ("Could not retrieve disk info for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                    # System info
                    try {
                        $sysInfo = Invoke-Command -ComputerName $machine.MachineName -ScriptBlock {
                            $os = Get-CimInstance -ClassName Win32_OperatingSystem
                            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
                            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
                            $av = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
                            [PSCustomObject]@{
                                OSVersion = $os.Version
                                LastBootTime = $os.LastBootUpTime
                                CPUCount = $cs.NumberOfLogicalProcessors
                                TotalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                                IsVirtual = if ($cs.Model -match 'Virtual|VMware|Hyper-V') { 1 } else { 0 }
                                Manufacturer = $cs.Manufacturer
                                Model = $cs.Model
                                Domain = $cs.Domain
                                PrimaryRole = $cs.DomainRole
                                ServicePack = $os.ServicePackMajorVersion
                                DiskFreeSpaceGB = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 2) } else { $null }
                                AntivirusProduct = if ($av) { ($av.displayName -join ', ') } else { $null }
                            }
                        } -ErrorAction Stop
                        if ($sysInfo) {
                            $osVersion = $sysInfo.OSVersion
                            $lastBootTime = $sysInfo.LastBootTime
                            $cpuCount = $sysInfo.CPUCount
                            $totalMemoryGB = $sysInfo.TotalMemoryGB
                            $isVirtual = $sysInfo.IsVirtual
                            $manufacturer = $sysInfo.Manufacturer
                            $model = $sysInfo.Model
                            $domain = $sysInfo.Domain
                            $primaryRole = $sysInfo.PrimaryRole
                            $servicePack = $sysInfo.ServicePack
                            $diskFreeSpaceGB = $sysInfo.DiskFreeSpaceGB
                            $antivirusProduct = $sysInfo.AntivirusProduct
                        }
                    } catch {
                        Write-Log -Message ("Could not retrieve system info for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "WARNING"
                    }
                } elseif ($winrmEnabled -and -not $canRunElevated) {
                    # Set all elevated scan results to null or default
                    $iisInstalledBit = $null
                    $dotNetFrameworkVersions = $null
                    $dotNetCoreVersions = $null
                    $osVersion = $null
                    $lastBootTime = $null
                    $cpuCount = $null
                    $totalMemoryGB = $null
                    $isVirtual = $null
                    $manufacturer = $null
                    $model = $null
                    $domain = $null
                    $primaryRole = $null
                    $servicePack = $null
                    $diskFreeSpaceGB = $null
                    $antivirusProduct = $null
                }
                # Test CIM/WMI connectivity
                $cimConnectivity = $null
                try {
                    $cimTest = $false
                    if ($winrmEnabled) {
                        try {
                            $cimTest = Invoke-Command -ComputerName $machine.MachineName -ScriptBlock {
                                try {
                                    $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                                    return $true
                                } catch { return $false }
                            } -ErrorAction Stop
                        } catch { $cimTest = $false }
                    }
                    $cimConnectivity = if ($cimTest) { 1 } else { 0 }
                } catch { $cimConnectivity = 0 }
                # Upsert logic for machine information (preserve existing data if new data is null)
                try {
                    $escapedMachineName = ToSqlValue($machine.MachineName)
                    $escapedOperatingSystem = ToSqlValue($machine.OperatingSystem)
                    $escapedDistinguishedName = ToSqlValue($machine.DistinguishedName)
                    $escapedDescription = ToSqlValue($machine.Description)
                    $escapedDNSHostName = ToSqlValue($machine.DNSHostName)
                    $escapedLastBootTime = ToSqlValue($lastBootTime)
                    $escapedAntivirusProduct = ToSqlValue($antivirusProduct)
                    $escapedNotes = ToSqlValue($notes)
                    $escapedDotNetFrameworkVersions = ToSqlValue($dotNetFrameworkVersions)
                    $escapedDotNetCoreVersions = ToSqlValue($dotNetCoreVersions)
                    $escapedEnvironment = ToSqlValue($environment)
                    $escapedIPAddress = ToSqlValue($ipAddress)
                    $escapedManufacturer = ToSqlValue($manufacturer)
                    $escapedModel = ToSqlValue($model)
                    $escapedDomain = ToSqlValue($domain)
                    $escapedPrimaryRole = ToSqlValue($primaryRole)
                    $escapedServicePack = ToSqlValue($servicePack)
                    $escapedOSVersion = ToSqlValue($osVersion)
                    $escapedLastSeen = ToSqlValue($lastSeen)
                    $escapedCPUCount = if ($null -eq $cpuCount -or $cpuCount -eq '') { 'NULL' } else { $cpuCount }
                    $escapedTotalMemoryGB = if ($null -eq $totalMemoryGB -or $totalMemoryGB -eq '') { 'NULL' } else { $totalMemoryGB }
                    $escapedIsVirtual = if ($null -eq $isVirtual -or $isVirtual -eq '') { 'NULL' } else { $isVirtual }
                    $escapedDiskFreeSpaceGB = if ($null -eq $diskFreeSpaceGB -or $diskFreeSpaceGB -eq '') { 'NULL' } else { $diskFreeSpaceGB }
                    $escapedADE = if ($null -eq $adEnabledBit -or $adEnabledBit -eq '') { 'NULL' } else { $adEnabledBit }
                    $escapedWinRM = if ($null -eq $winrmEnabledBit -or $winrmEnabledBit -eq '') { 'NULL' } else { $winrmEnabledBit }
                    $escapedIIS = if ($null -eq $iisInstalledBit -or $iisInstalledBit -eq '') { 'NULL' } else { $iisInstalledBit }
                    $escapedCIMConnectivity = if ($null -eq $cimConnectivity -or $cimConnectivity -eq '') { 'NULL' } else { $cimConnectivity }
                    $query = @"
MERGE INTO [$Table] AS target
USING (SELECT $escapedMachineName AS MachineName) AS source
ON target.MachineName = source.MachineName
WHEN MATCHED THEN
UPDATE SET
    target.OperatingSystem = CASE WHEN $escapedOperatingSystem IS NULL THEN target.OperatingSystem ELSE $escapedOperatingSystem END,
    target.OSVersion = CASE WHEN $escapedOSVersion IS NULL THEN target.OSVersion ELSE $escapedOSVersion END,
    target.AD_Enabled = CASE WHEN $escapedADE IS NULL THEN target.AD_Enabled ELSE $escapedADE END,
    target.WinRM_Enabled = CASE WHEN $escapedWinRM IS NULL THEN target.WinRM_Enabled ELSE $escapedWinRM END,
    target.IIS_Installed = CASE WHEN $escapedIIS IS NULL THEN target.IIS_Installed ELSE $escapedIIS END,
    target.DotNetFrameworkVersions = CASE WHEN $escapedDotNetFrameworkVersions IS NULL THEN target.DotNetFrameworkVersions ELSE $escapedDotNetFrameworkVersions END,
    target.DotNetCoreVersions = CASE WHEN $escapedDotNetCoreVersions IS NULL THEN target.DotNetCoreVersions ELSE $escapedDotNetCoreVersions END,
    target.DNSHostName = CASE WHEN $escapedDNSHostName IS NULL THEN target.DNSHostName ELSE $escapedDNSHostName END,
    target.IPAddress = CASE WHEN $escapedIPAddress IS NULL THEN target.IPAddress ELSE $escapedIPAddress END,
    target.DistinguishedName = CASE WHEN $escapedDistinguishedName IS NULL THEN target.DistinguishedName ELSE $escapedDistinguishedName END,
    target.Description = CASE WHEN $escapedDescription IS NULL THEN target.Description ELSE $escapedDescription END,
    target.Environment = CASE WHEN $escapedEnvironment IS NULL THEN target.Environment ELSE $escapedEnvironment END,
    target.CPUCount = CASE WHEN $escapedCPUCount IS NULL THEN target.CPUCount ELSE $escapedCPUCount END,
    target.TotalMemoryGB = CASE WHEN $escapedTotalMemoryGB IS NULL THEN target.TotalMemoryGB ELSE $escapedTotalMemoryGB END,
    target.IsVirtual = CASE WHEN $escapedIsVirtual IS NULL THEN target.IsVirtual ELSE $escapedIsVirtual END,
    target.Manufacturer = CASE WHEN $escapedManufacturer IS NULL THEN target.Manufacturer ELSE $escapedManufacturer END,
    target.Model = CASE WHEN $escapedModel IS NULL THEN target.Model ELSE $escapedModel END,
    target.Domain = CASE WHEN $escapedDomain IS NULL THEN target.Domain ELSE $escapedDomain END,
    target.PrimaryRole = CASE WHEN $escapedPrimaryRole IS NULL THEN target.PrimaryRole ELSE $escapedPrimaryRole END,
    target.ServicePack = CASE WHEN $escapedServicePack IS NULL THEN target.ServicePack ELSE $escapedServicePack END,
    target.DiskFreeSpaceGB = CASE WHEN $escapedDiskFreeSpaceGB IS NULL THEN target.DiskFreeSpaceGB ELSE $escapedDiskFreeSpaceGB END,
    target.AntivirusProduct = CASE WHEN $escapedAntivirusProduct IS NULL THEN target.AntivirusProduct ELSE $escapedAntivirusProduct END,
    target.LastBootTime = CASE WHEN $escapedLastBootTime IS NULL THEN target.LastBootTime ELSE $escapedLastBootTime END,
    target.LastSeen = $escapedLastSeen,
    target.Notes = CASE WHEN $escapedNotes IS NULL THEN target.Notes ELSE $escapedNotes END,
    target.CIM_Connectivity = CASE WHEN $escapedCIMConnectivity IS NULL THEN target.CIM_Connectivity ELSE $escapedCIMConnectivity END
WHEN NOT MATCHED THEN
INSERT (
    MachineName, OperatingSystem, OSVersion, AD_Enabled, WinRM_Enabled, IIS_Installed,
    DotNetFrameworkVersions, DotNetCoreVersions, DNSHostName, IPAddress, DistinguishedName, Description, Environment,
    CPUCount, TotalMemoryGB, IsVirtual, Manufacturer, Model, Domain, PrimaryRole, ServicePack, DiskFreeSpaceGB,
    AntivirusProduct, LastBootTime, LastSeen, Notes, CIM_Connectivity
) VALUES (
    $escapedMachineName, $escapedOperatingSystem, $escapedOSVersion, $escapedADE, $escapedWinRM, $escapedIIS,
    $escapedDotNetFrameworkVersions, $escapedDotNetCoreVersions, $escapedDNSHostName, $escapedIPAddress, $escapedDistinguishedName, $escapedDescription, $escapedEnvironment,
    $escapedCPUCount, $escapedTotalMemoryGB, $escapedIsVirtual, $escapedManufacturer, $escapedModel, $escapedDomain, $escapedPrimaryRole, $escapedServicePack, $escapedDiskFreeSpaceGB,
    $escapedAntivirusProduct, $escapedLastBootTime, $escapedLastSeen, $escapedNotes, $escapedCIMConnectivity
);
"@
                    try {
                        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction Stop
                    } catch {
                        Write-Log -Message ("ERROR upserting machine information for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "ERROR"
                        Write-Log -Message ("SQL QUERY: {0}" -f $query) -LogLevel "ERROR"
                    }
                } catch {
                    Write-Log -Message ("ERROR building upsert SQL for {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "ERROR"
                }
            } catch {
                Write-Log -Message ("ERROR processing {0}: {1}" -f $machine.MachineName, $_.Exception.Message) -LogLevel "ERROR"
            }
        }
        Write-Log -Message ("Machine list processing completed.") -LogLevel "INFO"
    } else {
        Write-Log -Message ("No machines retrieved from Active Directory.") -LogLevel "WARNING"
    }
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("Machine list script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}
#endregion

## appInventory.ps1
## Script to inventory Windows services on remote machines
## Based on certsOS.ps1 framework

# Debug Variables
$debugMode = $true
$errorCount = 0

# Path to the CSV file containing the list of remote machines
$csvFilePath = "C:\temp\machineList.csv"

# Output file for the inventory
$outputFile = "C:\temp\servicesInventory.csv"

#region Script Preferences
$scriptName = ($MyInvocation.MyCommand).Name
$scriptDir = if ($PSISE) { ($PSISE.CurrentFile.FullPath).Replace(('\{0}' -f $scriptName),'') } else { ($MyInvocation.MyCommand.Path).Replace(('\{0}' -f $scriptName),'') }
$textColorError = 'Red'
$textColorWarn = 'Yellow'
$textColorInfo = 'White'
$logFile = '{0}\Logs\{1}_{2}.log' -f $scriptDir, $scriptName.Replace('.ps1',''), (Get-Date -Format 'yyyyMMdd')
#endregion

#region Import Modules
Import-Module C:\Scripts\Powershell\Modules\Logging-Module
Import-Module C:\Scripts\Powershell\Modules\SQL-Module
#endregion

#region Functions
function Write-Log {
    param (
        [string]$message,
        [string]$logFilePath,
        [string]$color = $textColorInfo
    )
    if ($debugMode) {
        Write-Host -ForegroundColor $color $message
    } else {
        $message | Out-Info -logFilePath $logFilePath
    }
}

function Write-ErrorLog {
    param (
        [System.Management.Automation.ErrorRecord]$err,
        [string]$logFilePath
    )
    if ($debugMode) {
        Write-Host -ForegroundColor $textColorError $err
    } else {
        $err | Out-Error -logFilePath $logFilePath
    }
}

# Function to get services on a remote machine
function Get-RemoteServices {
    param (
        [string]$computerName
    )

    try {
        $services = Invoke-Command -ComputerName $computerName -ScriptBlock {
            Get-Service | ForEach-Object {
                $service = $_
                $serviceDetails = Get-WmiObject -Class Win32_Service -Filter "Name='$($service.Name)'"
                [PSCustomObject]@{
                    Name              = $serviceDetails.Name
                    DisplayName       = $serviceDetails.DisplayName
                    Status            = $serviceDetails.State
                    StartType         = $serviceDetails.StartMode
                    StartName         = $serviceDetails.StartName
                    ServiceType       = $serviceDetails.ServiceType
                    PathName          = $serviceDetails.PathName
                    Description       = $serviceDetails.Description
                    DependentServices = ($serviceDetails.DependentServices | ForEach-Object { $_.Name }) -join ", "
                }
            }
        } -ErrorAction Stop

        return $services
    } catch {
        Write-Host -ForegroundColor Red "Error retrieving services from: $computerName"
        $global:errorCount++
    }
}
#endregion

# Ensure the output directory exists
$outputDir = [System.IO.Path]::GetDirectoryName($outputFile)
if (-not (Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force
}

# Read machine names from the CSV file
$machineList = Import-Csv -Path $csvFilePath | Select-Object -ExpandProperty Name

#region ScriptMain()
try {
    # Iterate over each machine and get services
    foreach ($machine in $machineList) {
        $services = Get-RemoteServices -ComputerName $machine
        if ($services) {
            $services | Export-Csv -Path $outputFile -Append -NoTypeInformation
        }
    }
} catch {
    Write-ErrorLog -err $_ -logFilePath $logFile
    Write-Log -message ('ERROR: {0}' -f $_.Exception.Message) -logFilePath $logFile -color $textColorError
}
#endregion
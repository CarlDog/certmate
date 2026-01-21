## Collect OS Certificate Information
## Written by: Carl R Yeager
## Last Update: 20240905

#region Debug Preferences
$DebugMode = $true
$skipACL = $true
$skipCSV = $false
$skipSQL = $true
$skipCopy = $true
#endregion

#region Check for administrative privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Script needs to be run as an administrator. Restarting with elevated privileges..."
    Start-Process powershell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -NoExit -File `"" + $MyInvocation.MyCommand.Path + "`"") -Verb RunAs
    exit
}
#endregion

#region Import Modules
Import-Module C:\Scripts\Powershell\Modules\Logging-Module
Import-Module C:\Scripts\Powershell\Modules\SQL-Module
#endregion

#region My Preferences
$scriptName = ($MyInvocation.MyCommand).Name
$scriptDir = if ($PSISE) { ($PSISE.CurrentFile.FullPath).Replace(('\{0}' -f $scriptName),'') } else { ($MyInvocation.MyCommand.Path).Replace(('\{0}' -f $scriptName),'') }
$textColor_error = 'Red'
$textColor_warn = 'Yellow'
$textColor_info = 'White'
$logFile = '{0}\Logs\{1}_{2}.log' -f $scriptDir, $scriptName.Replace('.ps1',''), (Get-Date -Format 'yyyyMMdd')
#endregion

#region Script Parameters
$certStores = @( 'Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root')
$exportFile = '{0}\Exports\certsOS.csv' -f $scriptDir
$exportDir = Split-Path -Path $exportFile -Parent
$sharedDir = '\\cir\files\Shared\ProductionSupport\Inventory Management'
$ignoreCertificates = @() ## Ignore certificate containing these filters
$ignoreThumbprints = @() ## Ignore certificates matching these thumbprints 
$filterScript = {$_.Subject -notin $ignoreCertificates -and $_.Thumbprint -notin $ignoreThumbprints}
#endregion

#region Templates
$CERTIFICATE_OBJECT_TEMPLATE = {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certObj,
        [string]$svcAccounts
    )
    [pscustomobject]@{
        PSPath        = $certObj.PSPath
        Subject       = $certObj.Subject
        Issuer        = $certObj.Issuer
        Thumbprint    = $certObj.Thumbprint
        ValidFrom     = $certObj.NotBefore
        ValidTo       = $certObj.NotAfter
        ReadAccess    = $svcAccounts
    }
}
#endregion

#region Functions
function Write-Log {
    param (
        [string]$message,
        [string]$logFilePath,
        [string]$color = $textColor_info
    )
    if ($DebugMode) {
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
    if ($DebugMode) {
        Write-Host -ForegroundColor $textColor_error $err
    } else {
        $err | Out-Error -logFilePath $logFilePath
    }
}
function Format-Certificate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certObj,
        [Parameter(Mandatory = $true)]
        [string]$svcAccounts
    )
    process {
        $requiredKeys = & $CERTIFICATE_OBJECT_TEMPLATE -certObj $null -svcAccounts $null | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
        foreach ($key in $requiredKeys) {
            if (-not $certObj.PSObject.Properties.Match($key)) {
                throw "Certificate object is missing required key: $key"
            }
        }
        return & $CERTIFICATE_OBJECT_TEMPLATE -certObj $certObj -svcAccounts $svcAccounts
    }
}

function Get-CertStore {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$storePath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$filterScript
    )
    process {
        try {
            Get-ChildItem -Path $storePath -Recurse |
            Where-Object -Property Thumbprint |
            Where-Object -FilterScript $filterScript
        } catch {
            Write-ErrorLog -err $_ -logFilePath $logFile
            continue
        }
    }
}

function Get-SVCAccounts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certObj
    )
    process {
        if ($skipACL) {
            Write-Log "ACL Skipped..." -logFilePath $logFile
            return $null
        }
        try {
            $cert = Get-Item -Path $certObj.PSPath
            $filename = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
            $path = "$env:ALLUSERSPROFILE\Microsoft\Crypto\RSA\MachineKeys\$fileName"
            $permissions = Get-Acl -Path $path
            $access = $permissions.Access | Where-Object { $_.FileSystemRights -like "Read*" }
            $users = @($access.IdentityReference.Value)            
            $numUsers = $users.Count
            if ($DebugMode) {
                Write-Log ("{0}: {1}" -f $certObj.Thumbprint, $numUsers) -logFilePath $logFile
            }
        } catch {
            Write-ErrorLog -err $_ -logFilePath $logFile
            continue
        }
        return $users -join ',' -or $null
    }
}
#endregion

#region Validate Directories
Write-Log "Validating directories..." -logFilePath $logFile -color $textColor_warn
try {
    foreach ($dir in @($exportDir, $sharedDir)) {
        if (-not (Test-Path -Path $dir)) {
            Write-Log "Creating directory: $dir" -logFilePath $logFile
            New-Item -Path $dir -ItemType Directory -Force
        }
    }
} catch {
    Write-ErrorLog -err $_ -logFilePath $logFile
    Write-Log "An error occurred while validating directories." -logFilePath $logFile
}
#endregion

#region ScriptMain
Write-Log "Starting certificate processing..." -logFilePath $logFile -color $textColor_warn
try {
    $certArray = @()
    $totalStores = $certStores.Count
    $currentStoreIndex = 0

    foreach ($storePath in $certStores) {
        $currentStoreIndex++
        Write-Progress -Activity "Processing Certificate Stores" -Status "Processing $storePath" -PercentComplete (($currentStoreIndex / $totalStores) * 100)
        if ($DebugMode) {
            Write-Log "Processing certificate store: $storePath" -logFilePath $logFile
        }
        $certArray += Get-CertStore -storePath $storePath -filterScript $filterScript
    }

    if ($skipCSV) {
        Write-Log "Skipping CSV export..." -logFilePath $logFile
    } else {
        Write-Log "Formatting certificates and exporting to CSV..." -logFilePath $logFile   
        $certArray | ForEach-Object {
            try {
                if ($DebugMode) {
                    Write-Log "Processing certificate: $($_.Thumbprint)" -logFilePath $logFile
                }
                $svcAccounts = Get-SVCAccounts -certObj $_
                Format-Certificate -certObj $_ -svcAccounts ($svcAccounts -or "N/A")
            } catch {
                Write-ErrorLog -err $_ -logFilePath $logFile
                continue
            }
        } | Export-Csv -Path $exportFile -NoTypeInformation -Force    
    }

    if (-not $skipCopy) {
        Write-Log "Copying CSV to shared directory..." -logFilePath $logFile
        Copy-Item -Path $exportFile -Destination $sharedDir -Force
    }

    Write-Log "Certificate processing completed successfully." -logFilePath $logFile -color $textColor_warn
} catch {
    Write-ErrorLog -err $_ -logFilePath $logFile
    Write-Log "An error occurred during certificate processing." -logFilePath $logFile
} finally {
    Write-Log "Log file location: $logFile" -logFilePath $logFile
}
#endregion
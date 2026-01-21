## Certificate Repo Collection Script v2
## Written by: Carl R. Yeager
## Last Updated: 10052024

#region Debug Preferences
$DebugMode = $true
$skipRepo = $false
$skipCSV = $false
$skipSQL = $true
$skipCopy = $true
#endregion

#region Administrative Check
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

#region Script Preferences
$scriptName = ($MyInvocation.MyCommand).Name
$scriptDir = if ($PSISE) { ($PSISE.CurrentFile.FullPath).Replace(('\{0}' -f $scriptName),'') } else { ($MyInvocation.MyCommand.Path).Replace(('\{0}' -f $scriptName),'') }
$textColor_error = 'Red'
$textColor_warn = 'Yellow'
$textColor_info = 'White'
$logFile = '{0}\Logs\{1}_{2}.log' -f $scriptDir, $scriptName.Replace('.ps1',''), (Get-Date -Format 'yyyyMMdd')
#endregion

#region Script Parameters
$certRepository = '\\cir\files\Departments\Technology\IT\Certificates'
$exportFile = '{0}\Exports\certsRepo.csv' -f $scriptDir
$exportDir = Split-Path -Path $exportFile -Parent
$sharedDir = '\\cir\files\Shared\ProductionSupport\Inventory Management'
$ignoreCertificates = @() ## Ignore certificate containing these filters
$ignoreThumbprints = @() ## Ignore certificates matching these thumbprints 
$filterScript = {$_.Subject -notin $ignoreCertificates -and $_.Thumbprint -notin $ignoreThumbprints}
#endregion

#region Templates
$CERTIFICATE_OBJECT_TEMPLATE = {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate,
        [string]$filePath,
        [string]$fileExtension,
        [bool]$isArchived
    )
    [pscustomobject]@{
        FilePath      = $filePath
        FileExtension = $fileExtension
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

function Convert-CertificateFile {
    param (
        [System.IO.FileInfo]$file,
        [hashtable]$thumbprints,
        [scriptblock]$filterScript,
        [string]$logFile
    )
    $isArchived = $file.FullName -like "*\archived\*" -or $file.FullName -like "*\archive\*"
    $certificates = @()

    try {
        $certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList ($file.FullName)
        if (-not $thumbprints.ContainsKey($certificate.Thumbprint) -and (& $filterScript $certificate)) {
            $certificates += Format-Certificate -certificate $certificate -filePath $file.FullName -fileExtension $file.Extension -isArchived $isArchived
            $thumbprints[$certificate.Thumbprint] = $true
        }
    } catch {
        Write-Warning "Failed to process file: $($file.FullName). Error: $($_.Exception.Message)"
    }

    return $certificates
}

function Convert-PfxFile {
    param (
        [System.IO.FileInfo]$file,
        [hashtable]$thumbprints,
        [scriptblock]$filterScript,
        [string]$logFile
    )
    $certificates = @()
    $isArchived = $file.FullName -like "*\archived\*" -or $file.FullName -like "*\archive\*"
    $PasswordFile = ($file.FullName).Replace('.pfx', '.txt')
    $SecurePrivateKey = $null

    if (Test-Path $PasswordFile) {
        try {
            $PrivateKey = (Get-Content -Path $PasswordFile -ErrorAction Stop).ToString()
            if ($PrivateKey) {
                $SecurePrivateKey = ConvertTo-SecureString -String $PrivateKey -AsPlainText -Force
            }
        } catch {
            Write-Warning "Failed to read password file: $($PasswordFile). Error: $($_.Exception.Message)"
        }
    }

    try {
        $PFXData = if ($SecurePrivateKey) {
            (Get-PfxData -FilePath $file.FullName -Password $SecurePrivateKey -ErrorAction Stop).EndEntityCertificates
        } else {
            (Get-PfxData -FilePath $file.FullName -ErrorAction Stop).EndEntityCertificates
        }

        foreach ($certificate in $PFXData) {
            if (-not $thumbprints.ContainsKey($certificate.Thumbprint) -and (& $filterScript $certificate)) {
                $certificates += Format-Certificate -certificate $certificate -filePath $file.FullName -fileExtension $file.Extension -isArchived $isArchived
                $thumbprints[$certificate.Thumbprint] = $true
            }
        }
    } catch {
        if ($_.Exception.Message -match "ERROR_INVALID_PASSWORD") {
            # Silently ignore invalid password errors
        } else {
            Write-Warning "Failed to process PFX file: $($file.FullName). Error: $($_.Exception.Message)"
        }
    }

    return $certificates
}

function Format-Certificate {
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate,
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [string]$fileExtension,
        [Parameter(Mandatory = $true)]
        [bool]$isArchived
    )
    return & $CERTIFICATE_OBJECT_TEMPLATE -certificate $certificate -filePath $filePath -fileExtension $fileExtension -isArchived $isArchived
}

function Get-CertificateMetadata {
    param (
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$filterScript
    )
    $certificates = @()
    $thumbprints = @{}
    $pfxFiles = @()
    $crtFiles = @()

    try {
        # Recursively search for certificate files
        $files = Get-ChildItem -Path $filePath -Recurse -File -Include *.crt, *.pfx

        # Separate PFX and CRT files
        foreach ($file in $files) {
            switch ($file.Extension) {
                '.pfx' { $pfxFiles += $file }
                '.crt' { $crtFiles += $file }
            }
        }

        # Process CRT files
        $totalCrtFiles = $crtFiles.Count
        $processedCrtFiles = 0
        foreach ($file in $crtFiles) {
            $certificates += Convert-CertificateFile -file $file -thumbprints $thumbprints -filterScript $filterScript -logFile $logFile
            $processedCrtFiles++
            $percentComplete = [Math]::Min((($processedCrtFiles / $totalCrtFiles) * 100), 100)
            Write-Progress -Activity "Processing Certificates" -Status "Processing CRT files" -PercentComplete $percentComplete
        }

        # Process PFX files
        $totalPfxFiles = $pfxFiles.Count
        $processedPfxFiles = 0
        foreach ($file in $pfxFiles) {
            $certificates += Convert-PfxFile -file $file -thumbprints $thumbprints -filterScript $filterScript -logFile $logFile
            $processedPfxFiles++
            $percentComplete = [Math]::Min((($processedPfxFiles / $totalPfxFiles) * 100), 100)
            Write-Progress -Activity "Processing Certificates" -Status "Processing PFX files" -PercentComplete $percentComplete
        }
    } catch {
        Write-ErrorLog -err $_ -logFilePath $logFile
        Write-Log "Failed to search for certificate files in path: $filePath.`nError: $($_.Exception.Message)`nStackTrace:`n$($_.Exception.StackTrace)" -logFilePath $logFile
    } finally {
        # Clear the progress bar
        Write-Progress -Activity "Processing Certificates" -Status "Complete" -PercentComplete 100
    }

    return $certificates
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
    if (-not (Test-Path -Path $certRepository)) {
        throw "Certificate repository path does not exist: $certRepository"
    }
} catch {
    Write-ErrorLog -err $_ -logFilePath $logFile
    Write-Log "An error occurred while validating directories." -logFilePath $logFile
}
#endregion

#region ScriptMain
try {
    # Display debug options
    $debugOptions = Get-Variable -Name ($(Get-Variable).Name -like 'skip*') -ValueOnly | Where-Object { $_.Value -eq $true }
    if ($debugOptions) {
        Write-Host -Object 'DEBUG OPTIONS: ' -NoNewline
        Write-Host -ForegroundColor $textColor_warn -Object ($debugOptions.Name -join ', ')
    }

    # Get certificate metadata if not skipped
    if (!$skipRepo) {
        $certificates = Get-CertificateMetadata -filePath $certRepository -filterScript $filterScript
    }
    
    # Export results to CSV if not skipped
    if (!$skipCSV) {
        Write-Log 'Exporting collection results to CSV file(s) ...' -logFilePath $logFile
        if ($certificates) {
            Write-Log ("`tExporting {0} ..." -f $exportFile) -logFilePath $logFile
            $certificates | Export-Csv -Path $exportFile -Force -NoTypeInformation
        } else {
            Write-Log ("`tNo certificate objects found to export ...") -logFilePath $logFile -color $textColor_warn
        }
    }

    # Copy CSV files to shared directory if not skipped
    if (!$skipCopy) {
        Write-Log ('Copying CSV files to {0} ...' -f $sharedDir) -logFilePath $logFile
        $sourceFiles = Get-ChildItem -Path $exportDir -File -Filter *.csv
        foreach ($file in $sourceFiles) {
            Write-Log ("`tCopying {0} ..." -f $file.FullName) -logFilePath $logFile
            Copy-Item -Path $file.FullName -Destination $sharedDir -Force
        }
    }

} catch {
    Write-ErrorLog -err $_ -logFilePath $logFile
    Write-Log ('ERROR: {0}' -f $_.Exception.Message) -logFilePath $logFile -color $textColor_error
} finally {
    # Optional: Add any cleanup code here
}
#endregion
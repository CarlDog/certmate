# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "certsRepo" #Also used for $ScriptName
$ScriptName = $Table # Name for logging purposes
$LogTable = "collectionLogs"
$ErrorActionPreference = 'Continue'
$EnableDebugLogging = $true

# =====================
# Certificate Repository and Filtering
# =====================
$DriveLetter = 'Z:'  # Use the mapped drive letter (can be changed as needed)
$NetworkPath = '\\cir\files\Departments\Technology\IT\Certificates'

$ignoreCertificates = @()
$ignoreThumbprints = @()
$excludedSubstrings = @()
$filterScript = {
    param($cert, $file)
    return $true
}

# =====================
# Map/Remove Network Drive
# =====================
if (Test-Path $DriveLetter) {
    Remove-PSDrive -Name $DriveLetter.TrimEnd(':') -Force
}
New-PSDrive -Name $DriveLetter.TrimEnd(':') -PSProvider FileSystem -Root $NetworkPath -Persist

# =====================
# Certificate Object Template
# =====================
$CERTIFICATE_OBJECT_TEMPLATE = {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate,
        [string]$filePath,
        [string]$fileExtension,
        [bool]$isArchived
    )
    
    [pscustomobject]@{
        FilePath        = $filePath
        FileExtension   = $fileExtension
        Subject         = $certificate.Subject
        Issuer          = $certificate.Issuer
        Thumbprint      = $certificate.Thumbprint
        ThumbprintSHA256 = $certificate.GetCertHashString("SHA256")
        ValidFrom       = $certificate.NotBefore
        ValidTo         = $certificate.NotAfter
        IsArchived      = $isArchived
    }
}

# =====================
# Functions
# =====================
function Convert-CertificateFile {
    param (
        [System.IO.FileInfo]$file,
        [hashtable]$thumbprints,
        [scriptblock]$filterScript
    )
    $isArchived = $file.FullName -match '(?i)[\\/]#?archive[d]?([\\/]|$)'
    $certificates = @()
    try {
        if ($EnableDebugLogging -and ([string]::IsNullOrEmpty($file.FullName) -or $null -eq $file)) {
            Write-Log -Message ("DEBUG: Convert-CertificateFile called with empty or null file object. File: '{0}'" -f $file) -LogLevel "DEBUG"
        }
        $certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList ($file.FullName)
        # Debug logging for certificate properties
        if ($EnableDebugLogging) {
            Write-Log -Message ("Processing CRT file: {0}. Subject: {1}, Thumbprint: {2}" -f $file.FullName, $certificate.Subject, $certificate.Thumbprint) -LogLevel "DEBUG"
        }
        if ([string]::IsNullOrEmpty($certificate.Thumbprint)) {
            Write-Log -Message ("Skipping certificate with null or empty thumbprint. File: {0}, Subject: {1}" -f $file.FullName, $certificate.Subject) -LogLevel "WARNING"
            return $certificates
        }
        if (-not $thumbprints.ContainsKey($certificate.Thumbprint) -and (& $filterScript $certificate $file)) {
            $newCert = Format-Certificate -certificate $certificate -filePath $file.FullName -fileExtension $file.Extension -isArchived $isArchived
            if ($EnableDebugLogging -and ($newCert -and [string]::IsNullOrEmpty($newCert.FilePath))) {
                Write-Log -Message ("DEBUG: Convert-CertificateFile received certificate object with empty FilePath. File: {0}, Subject: {1}, Thumbprint: {2}" -f $file.FullName, $certificate.Subject, $certificate.Thumbprint) -LogLevel "DEBUG"
            }
            if ($newCert -and -not [string]::IsNullOrEmpty($newCert.FilePath)) {
                $certificates += $newCert
                $thumbprints[$certificate.Thumbprint] = $true
                if ($EnableDebugLogging) {
                    Write-Log -Message ("Added certificate to collection. File: {0}, Subject: {1}" -f $file.FullName, $certificate.Subject) -LogLevel "INFO"
                }
            } else {
                Write-Log -Message ("ERROR: Format-Certificate returned invalid object for file: {0}" -f $file.FullName) -LogLevel "ERROR"
            }
        } else {
            if ($EnableDebugLogging) {
                Write-Log -Message ("Skipping certificate (duplicate or filtered). File: {0}, Subject: {1}" -f $file.FullName, $certificate.Subject) -LogLevel "INFO"
            }
        }
    } catch {
        Write-Log -Message ("Failed to process certificate file: {0}. Error: {1}" -f $file.FullName, $_.Exception.Message) -LogLevel "ERROR"
    }
    finally {
        Write-Log -Message ("Exiting Convert-CertificateFile function.") -LogLevel "DEBUG"
    }
    return $certificates
}

function Convert-PfxFile {
    param (
        [System.IO.FileInfo]$file,
        [hashtable]$thumbprints,
        [scriptblock]$filterScript
    )
    $certificates = @()
    $isArchived = $file.FullName -match '(?i)[\\/]#?archive[d]?([\\/]|$)'
    $passwordFile = ($file.FullName).Replace('.pfx', '.txt')
    $securePrivateKey = $null
    # Try to read password from corresponding .txt file
    if (Test-Path $passwordFile) {
        try {
            $passwordText = Get-Content -Path $passwordFile -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($passwordText)) {
                $passwordText = $passwordText.Trim()
                $securePrivateKey = ConvertTo-SecureString -String $passwordText -AsPlainText -Force
                Write-Log -Message ("Using password file for PFX: {0}" -f $file.FullName) -LogLevel "INFO"
            }
        } catch {
            Write-Log -Message ("Failed to read password file: {0}. Error: {1}" -f $passwordFile, $_.Exception.Message) -LogLevel "WARNING"
        }
    } else {
        Write-Log -Message ("Password file not found for PFX: {0}" -f $passwordFile) -LogLevel "WARNING"
    }
    try {
        if ($EnableDebugLogging -and ([string]::IsNullOrEmpty($file.FullName) -or $null -eq $file)) {
            Write-Log -Message ("DEBUG: Convert-PfxFile called with empty or null file object. File: '{0}'" -f $file) -LogLevel "DEBUG"
        }
        $PFXData = $null
        if ($securePrivateKey) {
            $PFXData = (Get-PfxData -FilePath $file.FullName -Password $securePrivateKey -ErrorAction Stop).EndEntityCertificates
        } else {
            # Try without password (empty password or no password)
            $PFXData = (Get-PfxData -FilePath $file.FullName -ErrorAction Stop).EndEntityCertificates
        }
        Write-Log -Message ("Successfully loaded PFX data from: {0}. Found {1} certificates" -f $file.FullName, $PFXData.Count) -LogLevel "INFO"
        foreach ($certificate in $PFXData) {
            if ([string]::IsNullOrEmpty($certificate.Thumbprint)) {
                Write-Log -Message ("Skipping certificate with null or empty thumbprint in PFX file: {0}" -f $file.FullName) -LogLevel "WARNING"
                continue
            }
            if (-not $thumbprints.ContainsKey($certificate.Thumbprint) -and (& $filterScript $certificate $file)) {
                $newCert = Format-Certificate -certificate $certificate -filePath $file.FullName -fileExtension $file.Extension -isArchived $isArchived
                if ($EnableDebugLogging -and ($newCert -and [string]::IsNullOrEmpty($newCert.FilePath))) {
                    Write-Log -Message ("DEBUG: Convert-PfxFile received certificate object with empty FilePath. File: {0}, Subject: {1}, Thumbprint: {2}" -f $file.FullName, $certificate.Subject, $certificate.Thumbprint) -LogLevel "DEBUG"
                }
                if ($newCert -and -not [string]::IsNullOrEmpty($newCert.FilePath)) {
                    $certificates += $newCert
                    $thumbprints[$certificate.Thumbprint] = $true
                } else {
                    Write-Log -Message ("ERROR: Format-Certificate returned invalid object for PFX file: {0}" -f $file.FullName) -LogLevel "ERROR"
                }
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match "ERROR_INVALID_PASSWORD|password.*incorrect|invalid.*password") {
            Write-Log -Message ("Invalid password for PFX file: {0}. Check password file: {1}" -f $file.FullName, $passwordFile) -LogLevel "ERROR"
        } elseif ($errorMessage -match "password.*required") {
            Write-Log -Message ("Password required for PFX file: {0}. Password file: {1}" -f $file.FullName, $passwordFile) -LogLevel "ERROR"
        } else {
            Write-Log -Message ("Failed to process PFX file: {0}. Error: {1}" -f $file.FullName, $errorMessage) -LogLevel "ERROR"
        }
    }
    return $certificates
}

function Format-Certificate {
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate,
        [string]$filePath,
        [string]$fileExtension,
        [bool]$isArchived
    )
    $certObj = & $CERTIFICATE_OBJECT_TEMPLATE -certificate $certificate -filePath $filePath -fileExtension $fileExtension -isArchived $isArchived
    if ($EnableDebugLogging -and ([string]::IsNullOrEmpty($filePath) -or [string]::IsNullOrEmpty($certObj.FilePath))) {
        Write-Log -Message ("DEBUG: Format-Certificate called with empty filePath. Input filePath: '{0}', Result FilePath: '{1}', Subject: '{2}', Thumbprint: '{3}'" -f $filePath, $certObj.FilePath, $certificate.Subject, $certificate.Thumbprint) -LogLevel "DEBUG"
    }
    return $certObj
}

function Get-CertificateMetadata {
    param (
        [string]$filePath,
        [scriptblock]$filterScript
    )
    $certificates = @()
    $thumbprints = @{}
    $pfxFiles = @()
    $crtFiles = @()
    try {
        if (-not (Test-Path -Path $filePath)) {
            Write-Log -Message ("Certificate repository path does not exist: {0}" -f $filePath) -LogLevel "ERROR"
            return $certificates
        }
        Write-Log -Message ("Searching for certificate files in: {0}" -f $filePath) -LogLevel "INFO"
        $files = Get-ChildItem -Path $filePath -Recurse -File -Include *.crt, *.pfx
        foreach ($file in $files) {
            switch ($file.Extension) {
                '.pfx' { $pfxFiles += $file }
                '.crt' { $crtFiles += $file }
            }
        }
        Write-Log -Message ("Found {0} CRT files and {1} PFX files" -f $crtFiles.Count, $pfxFiles.Count) -LogLevel "INFO"
        $totalCrtFiles = $crtFiles.Count
        $processedCrtFiles = 0
        foreach ($file in $crtFiles) {
            $result = Convert-CertificateFile -file $file -thumbprints $thumbprints -filterScript $filterScript
            if ($result -and $result.Count -gt 0) {
                $certificates += $result
            }
            $processedCrtFiles++
            $percentComplete = [Math]::Min((($processedCrtFiles / $totalCrtFiles) * 100), 100)
            Write-Progress -Activity "Processing Certificates" -Status "Processing CRT files" -PercentComplete $percentComplete
        }
        $totalPfxFiles = $pfxFiles.Count
        $processedPfxFiles = 0
        foreach ($file in $pfxFiles) {
            $result = Convert-PfxFile -file $file -thumbprints $thumbprints -filterScript $filterScript
            if ($result -and $result.Count -gt 0) {
                $certificates += $result
            }
            $processedPfxFiles++
            $percentComplete = [Math]::Min((($processedPfxFiles / $totalPfxFiles) * 100), 100)
            Write-Progress -Activity "Processing Certificates" -Status "Processing PFX files" -PercentComplete $percentComplete
        }
        Write-Log -Message ("Processed a total of {0} unique certificates" -f $certificates.Count) -LogLevel "INFO"
        if ($EnableDebugLogging) {
            $emptyFilePathCerts = $certificates | Where-Object { $_ -and ([string]::IsNullOrEmpty($_.FilePath) -or [string]::IsNullOrEmpty($_.Thumbprint)) }
            if ($emptyFilePathCerts.Count -gt 0) {
                foreach ($badCert in $emptyFilePathCerts) {
                    Write-Log -Message ("DEBUG: Certificate object with missing FilePath or Thumbprint. FilePath: '{0}', Subject: '{1}', Thumbprint: '{2}'" -f $badCert.FilePath, $badCert.Subject, $badCert.Thumbprint) -LogLevel "DEBUG"
                }
            }
        }
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to search for certificate files in path: {0}.`nError: {1}" -f $filePath, $_.Exception.Message) -LogLevel "ERROR"
    } finally {
        Write-Progress -Activity "Processing Certificates" -Status "Complete" -PercentComplete 100
    }
    return $certificates
}

function Update-CertificateDatabase {
    param (
        [array]$certificates
    )
    try {
        $insertCount = 0
        $updateCount = 0
        $deleteCount = 0
        $skippedCount = 0
        
        # Filter out any invalid certificates before processing
        $validCertificates = @()
        foreach ($cert in $certificates) {
            if ($cert -and -not [string]::IsNullOrEmpty($cert.Thumbprint) -and -not [string]::IsNullOrEmpty($cert.FilePath)) {
                $validCertificates += $cert
                $mergeQuery = @"
DECLARE @MergeOutput TABLE (ActionType NVARCHAR(10));
MERGE INTO [$Table] AS Target
USING (SELECT N'$escapedThumbprint' AS [Thumbprint]) AS Source
ON Target.[Thumbprint] = Source.[Thumbprint]
WHEN MATCHED AND (
    Target.[FilePath] <> N'$escapedFilePath' OR
    Target.[FileExtension] <> N'$escapedFileExtension' OR
    Target.[Subject] <> N'$escapedSubject' OR
    Target.[Issuer] <> N'$escapedIssuer' OR
    Target.[ThumbprintSHA256] <> N'$escapedThumbprintSHA256' OR
    Target.[ValidFrom] <> '$validFromStr' OR
    Target.[ValidTo] <> '$validToStr' OR
    Target.[IsArchived] <> $isArchivedBit OR
    Target.[Notes] <> NULLIF(N'$escapedNotes', '')
)
THEN
    UPDATE SET
        [FilePath] = N'$escapedFilePath',
        [FileExtension] = N'$escapedFileExtension',
        [Subject] = N'$escapedSubject',
        [Issuer] = N'$escapedIssuer',
        [ThumbprintSHA256] = N'$escapedThumbprintSHA256',
        [ValidFrom] = '$validFromStr',
        [ValidTo] = '$validToStr',
        [IsArchived] = $isArchivedBit,
        [DateAdded] = '$dateAdded',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([CertificateId], [DateAdded], [FilePath], [FileExtension], [Subject], [Issuer], [Thumbprint], [ThumbprintSHA256], [ValidFrom], [ValidTo], [IsArchived], [Notes])
    VALUES ('$certificateId', '$dateAdded', N'$escapedFilePath', N'$escapedFileExtension', N'$escapedSubject', N'$escapedIssuer', N'$escapedThumbprint', N'$escapedThumbprintSHA256', '$validFromStr', '$validToStr', $isArchivedBit, NULLIF(N'$escapedNotes', ''))
OUTPUT `$action INTO @MergeOutput;
SELECT ActionType FROM @MergeOutput;
"@
            } else {
                $skippedCount++
                if ($cert) {
                    Write-Log -Message ("Skipping invalid certificate - FilePath: '{0}', Subject: '{1}', Thumbprint: '{2}'" -f $cert.FilePath, $cert.Subject, $cert.Thumbprint) -LogLevel "WARNING"
                } else {
                    Write-Log -Message ("Skipping null certificate object") -LogLevel "WARNING"
                }
            }
        }
        
        # Step 2: Collect current repository thumbprints
        $currentRepoThumbprints = @{}
        foreach ($cert in $validCertificates) {
            $currentRepoThumbprints[$cert.Thumbprint] = $true
        }
        
        Write-Log -Message ("Found {0} unique certificates in repository" -f $currentRepoThumbprints.Count) -LogLevel "INFO"
        
        # Step 3: Process each certificate from repository (INSERT or UPDATE)
        foreach ($cert in $validCertificates) {
            try {
                $originalFilePath = $cert.FilePath
                if ($originalFilePath -like 'Z:*') {
                    $originalFilePath = $originalFilePath -replace '^Z:', '\\cir\\files\\Departments\\Technology\\IT\\Certificates'
                }
                
                $certificateId = [guid]::NewGuid().ToString()
                $dateAdded = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
                $escapedFilePath = if ($originalFilePath) { $originalFilePath.Replace("'", "''") } else { "" }
                $escapedSubject = if ($cert.Subject) { $cert.Subject.Replace("'", "''") } else { "" }
                $escapedIssuer = if ($cert.Issuer) { $cert.Issuer.Replace("'", "''") } else { "" }
                $escapedThumbprint = if ($cert.Thumbprint) { $cert.Thumbprint.Replace("'", "''") } else { "" }
                $escapedThumbprintSHA256 = if ($cert.ThumbprintSHA256) { $cert.ThumbprintSHA256.Replace("'", "''") } else { "" }
                $validFromStr = $cert.ValidFrom.ToString('yyyy-MM-dd HH:mm:ss')
                $validToStr = $cert.ValidTo.ToString('yyyy-MM-dd HH:mm:ss')
                $isArchivedBit = if ($cert.IsArchived) { "1" } else { "0" }
                $escapedFileExtension = if ($cert.FileExtension) { $cert.FileExtension.Replace("'", "''") } else { "" }
                $escapedNotes = if ($null -ne $cert.Notes) { $cert.Notes.Replace("'", "''") } else { "" }
                
                $mergeQuery = @"
DECLARE @MergeOutput TABLE (ActionType NVARCHAR(10));
MERGE INTO [$Table] AS Target
USING (SELECT N'$escapedThumbprint' AS [Thumbprint]) AS Source
ON Target.[Thumbprint] = Source.[Thumbprint]
WHEN MATCHED THEN
    UPDATE SET
        [FilePath] = N'$escapedFilePath',
        [FileExtension] = N'$escapedFileExtension',
        [Subject] = N'$escapedSubject',
        [Issuer] = N'$escapedIssuer',
        [ThumbprintSHA256] = N'$escapedThumbprintSHA256',
        [ValidFrom] = '$validFromStr',
        [ValidTo] = '$validToStr',
        [IsArchived] = $isArchivedBit,
        [DateAdded] = '$dateAdded',
        [Notes] = NULLIF(N'$escapedNotes', '')
WHEN NOT MATCHED THEN
    INSERT ([CertificateId], [DateAdded], [FilePath], [FileExtension], [Subject], [Issuer], [Thumbprint], [ThumbprintSHA256], [ValidFrom], [ValidTo], [IsArchived], [Notes])
    VALUES ('$certificateId', '$dateAdded', N'$escapedFilePath', N'$escapedFileExtension', N'$escapedSubject', N'$escapedIssuer', N'$escapedThumbprint', N'$escapedThumbprintSHA256', '$validFromStr', '$validToStr', $isArchivedBit, NULLIF(N'$escapedNotes', ''))
OUTPUT `$action INTO @MergeOutput;
SELECT ActionType FROM @MergeOutput;
"@
                
                $result = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $mergeQuery -ErrorAction Stop
                $actionType = $result.ActionType
                
                if ($actionType -eq "INSERT") {
                    $insertCount++
                    Write-Log -Message ("Inserted new certificate: {0} - {1}" -f $cert.Thumbprint, $cert.Subject) -LogLevel "INFO"
                } elseif ($actionType -eq "UPDATE") {
                    $updateCount++
                    Write-Log -Message ("Updated existing certificate: {0} - {1}" -f $cert.Thumbprint, $cert.Subject) -LogLevel "INFO"
                }
                
            } catch {
                Write-Log -Message ("Failed to process certificate: {0}. File: {1}. Error: {2}" -f $cert.Thumbprint, $cert.FilePath, $_.Exception.Message) -LogLevel "ERROR"
                continue
            }
        }
        
        # Step 4: Remove certificates that no longer exist in the repository
        $certificatesToDelete = @()
        foreach ($dbThumbprint in $currentDbThumbprints.Keys) {
            if (-not $currentRepoThumbprints.ContainsKey($dbThumbprint)) {
                $certificatesToDelete += $dbThumbprint
            }
        }
        
        if ($certificatesToDelete.Count -gt 0) {
            Write-Log -Message ("Found {0} certificates to remove from database (no longer in repository)" -f $certificatesToDelete.Count) -LogLevel "INFO"
            
            foreach ($thumbprintToDelete in $certificatesToDelete) {
                try {
                    $escapedThumbprintToDelete = $thumbprintToDelete.Replace("'", "''")
                    $deleteQuery = "DELETE FROM [$Table] WHERE [Thumbprint] = N'$escapedThumbprintToDelete'"
                    Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $deleteQuery -ErrorAction Stop
                    $deleteCount++
                    Write-Log -Message ("Deleted certificate no longer in repository: {0}" -f $thumbprintToDelete) -LogLevel "INFO"
                } catch {
                    Write-Log -Message ("Failed to delete certificate: {0}. Error: {1}" -f $thumbprintToDelete, $_.Exception.Message) -LogLevel "ERROR"
                }
            }
        }
        
        Write-Log -Message ("Database synchronization completed - Inserted: {0}, Updated: {1}, Deleted: {2}, Total processed: {3}" -f $insertCount, $updateCount, $deleteCount, $validCertificates.Count) -LogLevel "INFO"
    } catch {
        $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message ("Failed to update certificate database. Error: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
}

function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Write-Output ("[{0}] {1}" -f $timestamp, $Message)
    if ($EnableDebugLogging -and $Message -like 'Exiting*function.') {
        $LogLevel = 'DEBUG'
    }
    try {
        $logId = [System.Guid]::NewGuid().ToString()
        $dbTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
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
        $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Write-Output ("[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message)
    }
}

# =====================
# Script Main
# =====================
try {
    Write-Log -Message ("Starting certificate repository script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"
                $skippedCount++
                if ($cert) {
                    Write-Log -Message ("Skipping invalid certificate - FilePath: '{0}', Subject: '{1}', Thumbprint: '{2}'" -f $cert.FilePath, $cert.Subject, $cert.Thumbprint) -LogLevel "WARNING"
                } else {
                    Write-Log -Message ("Skipping null certificate object") -LogLevel "WARNING"
                }
    $certificates = Get-CertificateMetadata -filePath $DriveLetter -filterScript $filterScript
    if ($certificates -and $certificates.Count -gt 0) {
        Write-Log -Message ("Updating SQL database with {0} certificates" -f $certificates.Count) -LogLevel "INFO"
        Update-CertificateDatabase -certificates $certificates
    } else {
        Write-Log -Message ("No certificates found to insert into the database") -LogLevel "WARNING"
    }
    Write-Log -Message ("Certificate repository script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = "ERROR: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("Certificate repository script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}

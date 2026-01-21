# =====================
# Certificate Expiry Alert Script
# Queries for certificates expiring within 30 days and sends individual webhook alerts
# Can be run as a SQL Server Agent job
# =====================

# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$ScriptName = "certExpiryAlert"
$LogTable = "collectionLogs"
$ErrorActionPreference = 'Continue'

# =====================
# Configuration
# =====================
$Config = @{
    DaysToCheck = 30
    CriticalThreshold = 7
    AlertLevels = @{ 'EXPIRED' = 1; 'CRITICAL' = 2; 'WARNING' = 3; 'OK' = 4 }
    
    CertSources = @{
        'Repository' = @{ Table = 'certsRepo'; LocationField = "COALESCE(FilePath, 'Certificate Store')"; DisplayName = 'Repository'; Filters = @('IsArchived = 0') }
        'OS' = @{ Table = 'certsOS'; LocationField = "CONCAT(MachineName, '\', StoreLocation, '\', StoreName)"; DisplayName = 'OS Store'; Filters = @() }
        'IIS' = @{ Table = 'certsIIS'; LocationField = "CONCAT(MachineName, '\', StoreLocation, '\', StoreName)"; DisplayName = 'IIS'; Filters = @() }
        'F5' = @{ Table = 'certsF5'; LocationField = "CONCAT(F5Node, '\', ProfileName)"; DisplayName = 'F5 Load Balancer'; Filters = @() }
    }
    
    GlobalFilters = @{
        DateRange = "CAST(ValidTo AS DATE) BETWEEN DATEADD(DAY, -{0}, CAST(GETDATE() AS DATE)) AND DATEADD(DAY, +{0}, CAST(GETDATE() AS DATE))"
        SubjectFilter = "Subject LIKE '%cir2.com%'"
    }
}

$AlertLevelCase = @"
CASE 
    WHEN CAST(ValidTo AS DATE) < CAST(GETDATE() AS DATE) THEN 'EXPIRED'
    WHEN CAST(ValidTo AS DATE) <= DATEADD(DAY, {0}, CAST(GETDATE() AS DATE)) THEN 'CRITICAL'
    WHEN CAST(ValidTo AS DATE) <= DATEADD(DAY, {1}, CAST(GETDATE() AS DATE)) THEN 'WARNING'
    ELSE 'OK'
END
"@ -f $Config.CriticalThreshold, $Config.DaysToCheck

# =====================
# Functions
# =====================

function Format-RepositoryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    
    $formattedPath = $Path
    # Replace common repository path with shorter label
    if ($Path.StartsWith('\cir\files\Departments\Technology\IT\Certificates')) {
        $formattedPath = $Path.Replace('\cir\files\Departments\Technology\IT\Certificates', '..')
    }
    # If still too long after repo replacement, apply truncation
    elseif ($Path.Length -gt 80) {
        # Split long paths at logical points (backslashes) for better readability
        $pathParts = $Path -split '\\'
        if ($pathParts.Count -gt 4) {
            # Show first part, ellipsis, and last 3 parts for very long paths
            $formattedPath = "{0}\...\{1}\{2}\{3}" -f $pathParts[0], $pathParts[-3], $pathParts[-2], $pathParts[-1]
        }
    }
    
    return $formattedPath
}

function Build-CertificateFilters {
    param([hashtable]$SourceConfig)
    
    try {
        $allFilters = @()
        foreach ($filter in $Config.GlobalFilters.GetEnumerator()) {
            switch ($filter.Key) {
                'DateRange' { $allFilters += "({0})" -f ($filter.Value -f $Config.DaysToCheck) }
                'SubjectFilter' { $allFilters += "({0})" -f $filter.Value }
                default { $allFilters += "({0})" -f $filter.Value }
            }
        }
        
        if ($SourceConfig.Filters -and $SourceConfig.Filters.Count -gt 0) {
            foreach ($filter in $SourceConfig.Filters) {
                if (-not [string]::IsNullOrWhiteSpace($filter)) {
                    $allFilters += "({0})" -f $filter
                }
            }
        }
        
        if ($allFilters.Count -gt 0) { 
            return $allFilters -join ' AND ' 
        } else { 
            return '1=1' 
        }
    } catch {
        Write-Log -Message ("Error building filters for source {0}: {1}" -f $SourceConfig.DisplayName, $_.Exception.Message) -LogLevel "ERROR"
        return '1=1'
    }
}

function Test-ConfigurationValidity {
    $isValid = $true
    $validationErrors = @()
    
    if (-not $Config.CertSources -or $Config.CertSources.Count -eq 0) {
        $validationErrors += "No certificate sources configured"
        $isValid = $false
    } else {
        foreach ($source in $Config.CertSources.GetEnumerator()) {
            $sourceConfig = $source.Value
            if ([string]::IsNullOrWhiteSpace($sourceConfig.Table)) {
                $validationErrors += "Certificate source '{0}' missing Table configuration" -f $source.Key
                $isValid = $false
            }
            if ([string]::IsNullOrWhiteSpace($sourceConfig.LocationField)) {
                $validationErrors += "Certificate source '{0}' missing LocationField configuration" -f $source.Key
                $isValid = $false
            }
            if ([string]::IsNullOrWhiteSpace($sourceConfig.DisplayName)) {
                $validationErrors += "Certificate source '{0}' missing DisplayName configuration" -f $source.Key
                $isValid = $false
            }
        }
    }
    
    if (-not $Config.GlobalFilters) {
        $validationErrors += "No global filters configured"
        $isValid = $false
    }
    
    if ($Config.DaysToCheck -le 0) {
        $validationErrors += "DaysToCheck must be greater than 0"
        $isValid = $false
    }
    
    if ($Config.CriticalThreshold -le 0) {
        $validationErrors += "CriticalThreshold must be greater than 0"
        $isValid = $false
    }
    
    if ($isValid) {
        Write-Log -Message "Configuration validation passed" -LogLevel "INFO"
        return $true
    } else {
        foreach ($validationError in $validationErrors) {
            Write-Log -Message ("Configuration error: {0}" -f $validationError) -LogLevel "ERROR"
        }
        return $false
    }
}
function Write-Log {
    param (
        [string]$Message,
        [string]$LogLevel = "INFO",
        [string]$AdditionalInfo = $null
    )
    
    # Skip console output for DEBUG messages during alert formatting
    if ($LogLevel -ne "DEBUG" -or $DebugPreference -ne 'SilentlyContinue') {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Write-Output ("[{0}] [{1}] {2}" -f $timestamp, $LogLevel, $Message)
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
    '{0}', '{1}', N'{2}', N'{3}', N'{4}', NULL
)
"@ -f $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage
        } else {
            $escapedAdditionalInfo = $AdditionalInfo.Replace("'", "''")
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]
) VALUES (
    '{0}', '{1}', N'{2}', N'{3}', N'{4}', N'{5}'
)
"@ -f $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage, $escapedAdditionalInfo
        }
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction SilentlyContinue
    } catch {
        # Only show database errors if not in silent debug mode
        if ($LogLevel -ne "DEBUG" -or $DebugPreference -ne 'SilentlyContinue') {
            $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            Write-Output "[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message
        }
    }
}

function Get-ExpiringCertificates {
    <#
    .SYNOPSIS
    Queries the database for certificates expiring within the specified timeframe
    
    .DESCRIPTION
    Dynamically builds and executes a SQL query to find certificates from all configured
    certificate tables that are expiring within the specified time range, then groups
    them by subject to avoid duplicate alerts for the same certificate
    #>
    
    try {
        Write-Log -Message ("Querying database for certificates expiring within {0} days" -f $Config.DaysToCheck) -LogLevel "INFO"
        
        # Build UNION queries for each certificate source
        $unionQueries = @()
        foreach ($source in $Config.CertSources.GetEnumerator()) {
            # Build the WHERE clause using the unified filter system
            $whereClause = Build-CertificateFilters -SourceConfig $source.Value
            
            Write-Log -Message ("Filter for {0}: {1}" -f $source.Value.DisplayName, $whereClause) -LogLevel "DEBUG"
            
            $unionQueries += @"
    SELECT 
        '{0}' as CertificateSource,
        {1} as Location,
        Subject,
        Issuer,
        Thumbprint,
        ValidFrom,
        ValidTo,
        DATEDIFF(DAY, CAST(GETDATE() AS DATE), CAST(ValidTo AS DATE)) as DaysToExpiry,
        {2} as AlertLevel
    FROM {3}
    WHERE {4}
"@ -f $source.Value.DisplayName, $source.Value.LocationField, $AlertLevelCase, $source.Value.Table, $whereClause
        }
        
        # Add debug query to count raw results before grouping
        $debugQuery = @"
WITH ExpiringCertificates AS (
{0}
)
SELECT 
    CertificateSource,
    COUNT(*) as RawCount
FROM ExpiringCertificates
GROUP BY CertificateSource
ORDER BY CertificateSource
"@ -f ($unionQueries -join "`n    UNION ALL`n")
        
        $debugResults = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $debugQuery
        Write-Log -Message ("Raw certificate counts by source: {0}" -f (($debugResults | ForEach-Object { "{0}={1}" -f $_.CertificateSource, $_.RawCount }) -join ', ')) -LogLevel "DEBUG"
        
        # Modified query to group by subject and collect all locations
        $query = @"
WITH ExpiringCertificates AS (
{0}
),
GroupedCertificates AS (
    SELECT 
        Subject,
        Issuer,
        MIN(Thumbprint) as Thumbprint,
        MIN(ValidFrom) as ValidFrom,
        MAX(ValidTo) as ValidTo,
        MIN(DaysToExpiry) as DaysToExpiry,
        -- Use priority-based alert level selection
        CASE 
            WHEN MIN(CASE WHEN AlertLevel = 'EXPIRED' THEN 1 
                          WHEN AlertLevel = 'CRITICAL' THEN 2 
                          WHEN AlertLevel = 'WARNING' THEN 3 
                          ELSE 4 END) = 1 THEN 'EXPIRED'
            WHEN MIN(CASE WHEN AlertLevel = 'EXPIRED' THEN 1 
                          WHEN AlertLevel = 'CRITICAL' THEN 2 
                          WHEN AlertLevel = 'WARNING' THEN 3 
                          ELSE 4 END) = 2 THEN 'CRITICAL'
            WHEN MIN(CASE WHEN AlertLevel = 'EXPIRED' THEN 1 
                          WHEN AlertLevel = 'CRITICAL' THEN 2 
                          WHEN AlertLevel = 'WARNING' THEN 3 
                          ELSE 4 END) = 3 THEN 'WARNING'
            ELSE 'OK'
        END as AlertLevel,
        STRING_AGG(Location, '; ') WITHIN GROUP (ORDER BY CertificateSource, Location) as AllLocations,
        COUNT(*) as LocationCount
    FROM ExpiringCertificates
    GROUP BY Subject, Issuer
    -- Add HAVING clause to ensure we only get certificates that actually need attention
    HAVING MIN(DaysToExpiry) <= 30
)
SELECT 
    Subject,
    Issuer,
    Thumbprint,
    ValidFrom,
    ValidTo,
    DaysToExpiry,
    AlertLevel,
    AllLocations,
    LocationCount
FROM GroupedCertificates
ORDER BY 
    CASE 
        WHEN AlertLevel = 'EXPIRED' THEN 1
        WHEN AlertLevel = 'CRITICAL' THEN 2
        WHEN AlertLevel = 'WARNING' THEN 3
        ELSE 4
    END,
    DaysToExpiry ASC,
    Subject
"@ -f ($unionQueries -join "`n    UNION ALL`n")
        
        $results = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query
        
        # Log final grouped results
        if ($results.Count -gt 0) {
            $alertBreakdown = $results | Group-Object AlertLevel | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Count }
            Write-Log -Message ("Final results: {0} unique certificates ({1})" -f $results.Count, ($alertBreakdown -join ', ')) -LogLevel "DEBUG"
            
            # Debug: Show first few certificates with their location data
            $debugCerts = $results | Select-Object -First 3
            foreach ($cert in $debugCerts) {
                $debugInfo = "Subject: {0} | AllLocations: '{1}' | LocationCount: {2}" -f $cert.Subject, $cert.AllLocations, $cert.LocationCount
                Write-Log -Message $debugInfo -LogLevel "DEBUG"
            }
        } else {
            Write-Log -Message "No certificates found matching criteria" -LogLevel "DEBUG"
        }
        
        return $results
        
    } catch {
        $errorMessage = "Failed to query expiring certificates: {0}" -f $_.Exception.Message
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        throw $errorMessage
    }
}

function Send-IndividualCertificateAlert {
    param([object]$certificate)
    
    try {
        Write-Log -Message ("Sending individual Teams notification for certificate: {0}" -f $certificate.Subject) -LogLevel "INFO"
        
        # Determine alert level - no need for redundant title
        $alertLevel = $certificate.AlertLevel
        $alertTitle = ""  # Empty title since Teams card has clear activity title
        
        # Build status and validation texts
        $statusText = switch ($certificate.DaysToExpiry) {
            {$_ -lt 0} { "**EXPIRED {0} days ago**" -f [Math]::Abs($_) }
            0 { "**EXPIRES TODAY**" }
            default { "**Expires in {0} days**" -f $_ }
        }
        
        $validToText = if ($certificate.ValidTo) { 
            $certificate.ValidTo.ToString('yyyy-MM-dd HH:mm:ss') 
        } else { 
            "Unknown" 
        }
        
        # Process locations inline (like the original script)
        $allLocations = @()
        if ($certificate.AllLocations -and (-not [string]::IsNullOrWhiteSpace($certificate.AllLocations))) {
            $splitLocations = $certificate.AllLocations -split '; '
            foreach ($splitLocation in $splitLocations) {
                $location = $splitLocation.Trim()
                # Keep locations that aren't empty, aren't just backslashes, and have meaningful content
                if ($location -and 
                    ($location -ne '') -and 
                    ($location -ne '\') -and 
                    ($location -ne '\\') -and 
                    ($location.Length -gt 1) -and
                    (-not ($location -match '^\\+$'))) {
                    $allLocations += $location
                }
            }
        }
        
        # Remove duplicates
        $uniqueLocations = @()
        foreach ($location in $allLocations) {
            if ($uniqueLocations -notcontains $location) {
                $uniqueLocations += $location
            }
        }
        
        # Build location text
        $locationText = if ($uniqueLocations.Count -eq 0) {
            "*No location data available*"
        } elseif ($uniqueLocations.Count -eq 1) {
            "**Location**: {0}" -f (Format-RepositoryPath -Path $uniqueLocations[0])
        } else {
            "**Locations** ({0} total):`n{1}" -f $uniqueLocations.Count, (($uniqueLocations | ForEach-Object { "• {0}" -f (Format-RepositoryPath -Path $_) }) -join "`n")
        }
        
        # Build alert message
        $alertMessage = @"
**Certificate Details:**
- **Status**: {0}
- **Valid To**: {1}
- **Issuer**: {2}
- **Thumbprint**: {3}

**Location Information:**
{4}

---
**Action Required:** Review and renew this certificate immediately.
"@ -f $statusText, $validToText, $certificate.Issuer, $certificate.Thumbprint, $locationText
        
        # Create technical data and certificate section
        $alertData = "Subject: {0} | DaysToExpiry: {1} | LocationCount: {2}" -f $certificate.Subject, $certificate.DaysToExpiry, $uniqueLocations.Count
        
        $sectionText = "**Status:** {0}  `n**Valid To:** {1}  `n**Issuer:** {2}  `n**Thumbprint:** {3}  `n" -f $statusText.Replace("**", ""), $validToText, $certificate.Issuer, $certificate.Thumbprint
        
        if ($uniqueLocations.Count -eq 0) {
            $sectionText += "**Location:** *No location data available*"
        } elseif ($uniqueLocations.Count -eq 1) {
            $sectionText += "**Location:** {0}" -f (Format-RepositoryPath -Path $uniqueLocations[0])
        } else {
            $sectionText += "**Locations** ({0} total):  `n{1}" -f $uniqueLocations.Count, (($uniqueLocations | ForEach-Object { "• {0}  `n" -f (Format-RepositoryPath -Path $_) }) -join "")
            $sectionText = $sectionText.TrimEnd(" `n")
        }
        
        $certificateDataString = "{0}|{1}" -f $certificate.Subject, $sectionText
        $certificateDataString = $certificateDataString.Replace("'", "''")
        
        # Send notification
        $query = @"
DECLARE @Result int;
EXEC [dbo].[InventorySendTeamsNotification] 
    @AlertTitle = N'{0}',
    @AlertMessage = N'{1}',
    @AlertType = N'Certificate Expiry Alert',
    @AlertLevel = N'{2}',
    @AlertData = N'{3}',
    @CertificateData = N'{4}',
    @DebugMode = 0;
"@ -f $alertTitle.Replace("'", "''"), $alertMessage.Replace("'", "''"), $alertLevel, $alertData.Replace("'", "''"), $certificateDataString

        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction Stop
        
        Write-Log -Message ("Individual Teams notification sent successfully for certificate: {0}" -f $certificate.Subject) -LogLevel "INFO"
        return $true
        
    } catch {
        $errorMessage = "Failed to send individual Teams notification for certificate '{0}': {1}" -f $certificate.Subject, $_.Exception.Message
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        return $false
    }
}




# =====================
# Main Script Execution
# =====================
try {
    Write-Log -Message "Starting certificate expiry alert script" -LogLevel "INFO"
    
    # Validate configuration before proceeding
    if (-not (Test-ConfigurationValidity)) {
        throw "Configuration validation failed. Please check the configuration and try again."
    }
    
    Write-Log -Message ("Checking for certificates expiring within {0} days from {1} certificate sources" -f $Config.DaysToCheck, $Config.CertSources.Count) -LogLevel "INFO"
    
    # Log the active filters for transparency
    Write-Log -Message ("Active global filters: {0}" -f (($Config.GlobalFilters.Keys | ForEach-Object { $_ }) -join ', ')) -LogLevel "INFO"
    
    # Get expiring certificates
    $expiringCertificates = Get-ExpiringCertificates
    
    if ($null -eq $expiringCertificates -or $expiringCertificates.Count -eq 0) {
        Write-Log -Message ("No certificates found expiring within {0} days" -f $Config.DaysToCheck) -LogLevel "INFO"
        Write-Log -Message "Certificate expiry alert script completed successfully - no alerts needed" -LogLevel "INFO"
        exit 0
    }
    
    # Process results and create alerts
    $uniqueSubjectCount = ($expiringCertificates | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
    Write-Log -Message ("Found {0} total certificate records representing {1} unique certificate subjects expiring within {2} days" -f $expiringCertificates.Count, $uniqueSubjectCount, $Config.DaysToCheck) -LogLevel "INFO"
    
    # Create alert summary using group counts
    $alertCounts = $expiringCertificates | Group-Object AlertLevel | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Count }
    Write-Log -Message ("Alert breakdown by database records - {0}" -f ($alertCounts -join ', ')) -LogLevel "INFO"
    
    # Create alert summary using unique subjects
    $subjectAlertCounts = @()
    foreach ($alertLevel in @('EXPIRED', 'CRITICAL', 'WARNING')) {
        $subjectCount = ($expiringCertificates | Where-Object { $_.AlertLevel -eq $alertLevel } | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
        if ($subjectCount -gt 0) {
            $subjectAlertCounts += "{0}: {1} subjects" -f $alertLevel, $subjectCount
        }
    }
    if ($subjectAlertCounts.Count -gt 0) {
        Write-Log -Message ("Alert breakdown by unique subjects - {0}" -f ($subjectAlertCounts -join ', ')) -LogLevel "INFO"
    }
    
    # Debug: Check for certificates with blank/null alert levels
    $blankAlertCerts = $expiringCertificates | Where-Object { [string]::IsNullOrEmpty($_.AlertLevel) }
    if ($blankAlertCerts.Count -gt 0) {
        Write-Log -Message ("Found {0} certificates with blank AlertLevel - {1}" -f $blankAlertCerts.Count, (($blankAlertCerts | Select-Object -First 3 | ForEach-Object { "Subject: {0}, DaysToExpiry: {1}" -f $_.Subject, $_.DaysToExpiry }) -join '; ')) -LogLevel "DEBUG"
    }

    # Send individual alerts for each certificate
    $successCount = 0
    $failureCount = 0
    
    Write-Log -Message ("Sending individual Teams notifications for {0} certificates" -f $expiringCertificates.Count) -LogLevel "INFO"
    
    foreach ($certificate in $expiringCertificates) {
        # Skip certificates with missing critical data
        if ([string]::IsNullOrEmpty($certificate.Subject) -or [string]::IsNullOrEmpty($certificate.Issuer)) {
            Write-Log -Message ("Skipping certificate with missing data - Subject: '{0}', Issuer: '{1}'" -f $certificate.Subject, $certificate.Issuer) -LogLevel "WARNING"
            continue
        }
        
        $alertSuccess = Send-IndividualCertificateAlert -certificate $certificate
        
        if ($alertSuccess) {
            $successCount++
        } else {
            $failureCount++
        }
        
        # Add a small delay between notifications to avoid overwhelming the webhook
        Start-Sleep -Milliseconds 500
    }
    
    # Log summary of notification results
    Write-Log -Message ("Individual certificate notifications completed - Success: {0}, Failures: {1}" -f $successCount, $failureCount) -LogLevel "INFO"
    
    if ($failureCount -gt 0) {
        Write-Log -Message ("Some certificate notifications failed - check logs for details") -LogLevel "ERROR"
    }
    
    Write-Log -Message "Certificate expiry alert script completed successfully" -LogLevel "INFO"
    
} catch {
    $errorMessage = "Certificate expiry alert script failed: {0}`nStackTrace: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    
    # Try to send error alert via 'ProdSpt Certificate Notifications' Teams webhook
    try {
        $errorQuery = @"
DECLARE @Result int;
EXEC [dbo].[InventorySendTeamsNotification] 
    @AlertTitle = N'Certificate Alert System Error',
    @AlertMessage = N'Certificate expiry alert script failed to execute properly. Details: {0}',
    @AlertType = N'Certificate System Error',
    @AlertLevel = N'ERROR',
    @AlertData = N'Script: {1}, Server: {2}, Database: {3}',
    @DebugMode = 0;
"@ -f $_.Exception.Message.Replace("'", "''"), $ScriptName, $Server, $Database
        
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $errorQuery -ErrorAction SilentlyContinue
    } catch {
        Write-Log -Message ("Failed to send 'ProdSpt Certificate Notifications' error alert: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
    }
    
    exit 1
    
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -LogLevel "INFO"
}

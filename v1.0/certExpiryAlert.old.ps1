# =====================
# Certificate Expiry Alert Script
# Queries for certificates expiring within 30 days and sends webhook alerts
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
    # Alert settings
    DaysToCheck = 30
    MaxCertificatesInAlert = 50
    CriticalThreshold = 7  # Days for critical alerts
    
    # Alert levels and their priorities (lower number = higher priority)
    AlertLevels = @{
        'EXPIRED' = 1
        'CRITICAL' = 2
        'WARNING' = 3
        'OK' = 4
    }
    
    # Certificate sources configuration
    CertSources = @{
        'Repository' = @{
            Table = 'certsRepo'
            LocationField = "COALESCE(FilePath, 'Certificate Store')"
            DisplayName = 'Repository'
            Filters = @(
                'IsArchived = 0'  # Exclude archived certificates
            )
        }
        'OS' = @{
            Table = 'certsOS'
            LocationField = "CONCAT(MachineName, '\', StoreLocation, '\', StoreName)"
            DisplayName = 'OS Store'
            Filters = @(
                # Add OS-specific filters here if needed
            )
        }
        'IIS' = @{
            Table = 'certsIIS'
            LocationField = "CONCAT(MachineName, '\', StoreLocation, '\', StoreName)"
            DisplayName = 'IIS'
            Filters = @(
                # Add IIS-specific filters here if needed
            )
        }
        'F5' = @{
            Table = 'certsF5'
            LocationField = "CONCAT(F5Node, '\', ProfileName)"
            DisplayName = 'F5 Load Balancer'
            Filters = @(
                # Add F5-specific filters here if needed
            )
        }
    }
    
    # Global filters applied to all certificate sources
    GlobalFilters = @{
        DateRange = "CAST(ValidTo AS DATE) BETWEEN DATEADD(DAY, -{0}, CAST(GETDATE() AS DATE)) AND DATEADD(DAY, +{0}, CAST(GETDATE() AS DATE))"
        SubjectFilter = "Subject LIKE '%cir2.com%'"
        # Add more global filters here as needed
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
    <#
    .SYNOPSIS
    Formats a file path by applying repository path replacement and truncation
    
    .DESCRIPTION
    Applies consistent formatting to file paths, including repository path replacement
    and truncation for very long paths
    #>
    param(
        [string]$Path
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    
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
    <#
    .SYNOPSIS
    Builds the complete WHERE clause for a certificate source by combining global and source-specific filters
    
    .DESCRIPTION
    Takes global filters and source-specific filters and combines them into a single WHERE clause
    #>
    param(
        [hashtable]$SourceConfig
    )
    
    try {
        $allFilters = @()
        
        # Add global filters
        foreach ($filter in $Config.GlobalFilters.GetEnumerator()) {
            switch ($filter.Key) {
                'DateRange' {
                    $allFilters += "({0})" -f ($filter.Value -f $Config.DaysToCheck)
                }
                'SubjectFilter' {
                    $allFilters += "({0})" -f $filter.Value
                }
                default {
                    $allFilters += "({0})" -f $filter.Value
                }
            }
        }
        
        # Add source-specific filters
        if ($SourceConfig.Filters -and $SourceConfig.Filters.Count -gt 0) {
            foreach ($filter in $SourceConfig.Filters) {
                if (-not [string]::IsNullOrWhiteSpace($filter)) {
                    $allFilters += "({0})" -f $filter
                }
            }
        }
        
        # Combine all filters with AND
        if ($allFilters.Count -gt 0) {
            return $allFilters -join ' AND '
        } else {
            return '1=1'  # Default condition if no filters
        }
        
    } catch {
        Write-Log -Message ("Error building filters for source {0}: {1}" -f $SourceConfig.DisplayName, $_.Exception.Message) -LogLevel "ERROR"
        return '1=1'  # Fallback condition
    }
}

function Test-ConfigurationValidity {
    <#
    .SYNOPSIS
    Validates the configuration settings before script execution
    
    .DESCRIPTION
    Checks that all required configuration elements are present and valid
    #>
    
    $isValid = $true
    $validationErrors = @()
    
    # Check certificate sources
    if (-not $Config.CertSources -or $Config.CertSources.Count -eq 0) {
        $validationErrors += "No certificate sources configured"
        $isValid = $false
    } else {
        foreach ($source in $Config.CertSources.GetEnumerator()) {
            $sourceConfig = $source.Value
            
            # Check required fields
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
    
    # Check global filters
    if (-not $Config.GlobalFilters) {
        $validationErrors += "No global filters configured"
        $isValid = $false
    }
    
    # Check numeric settings
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

function Format-AlertMessage {
    param (
        [array]$certificates
    )

    if ($null -eq $certificates -or $certificates.Count -eq 0) {
        return $null
    }

    # Temporarily suppress debug logging during alert formatting
    $originalDebugPreference = $DebugPreference
    $DebugPreference = 'SilentlyContinue'

    try {
        # Group certificates by alert level and sort by priority
        $groupedCerts = $certificates | Group-Object AlertLevel | Sort-Object @{Expression={$Config.AlertLevels[$_.Name]}}

        # Build alert message
        $alertLines = @()

    # Add detailed certificate information
    foreach ($group in $groupedCerts) {
        # Skip groups with empty names
        if ([string]::IsNullOrEmpty($group.Name)) {
            continue
        }

        # Skip section headers - they're redundant with the alert title
        # Only show section header if we have multiple alert levels
        # if ($groupedCerts.Count -gt 1) {
        #     $alertLines += "**{0} Certificates:**" -f $group.Name
        #     $alertLines += ""
        # }

        # Group certificates by subject within each alert level to combine duplicates
        $subjectGroups = $group.Group | Group-Object Subject | Sort-Object @{Expression={$_.Group | ForEach-Object {$_.DaysToExpiry} | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum}}

        # Limit certificate subjects shown to avoid overly large messages
        $subjectsToShow = $subjectGroups | Select-Object -First $Config.MaxCertificatesInAlert

        foreach ($subjectGroup in $subjectsToShow) {
            # Get the certificate with the most urgent expiry date for this subject
            $primaryCert = $subjectGroup.Group | Sort-Object DaysToExpiry | Select-Object -First 1
            
            # Skip certificates with missing critical data
            if ([string]::IsNullOrEmpty($primaryCert.Subject) -or [string]::IsNullOrEmpty($primaryCert.Issuer)) {
                continue
            }

            $statusText = switch ($primaryCert.DaysToExpiry) {
                {$_ -lt 0} { "**EXPIRED {0} days ago**" -f [Math]::Abs($_) }
                0 { "**EXPIRES TODAY**" }
                default { "**Expires in {0} days**" -f $_ }
            }

            # Combine all locations from all certificates with this subject
            $allLocations = @()
            foreach ($cert in $subjectGroup.Group) {
                if ($cert.AllLocations -and (-not [string]::IsNullOrWhiteSpace($cert.AllLocations))) {
                    # Split locations and clean them up, avoiding problematic Where-Object filtering
                    $splitLocations = $cert.AllLocations -split '; '
                    
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
            }                # Remove duplicates without using Sort-Object which corrupts backslashes
                $uniqueLocations = @()
                foreach ($location in $allLocations) {
                    if ($uniqueLocations -notcontains $location) {
                        $uniqueLocations += $location
                    }
                }
                $allLocations = $uniqueLocations

            # Safe date formatting
            $validToText = if ($primaryCert.ValidTo) { 
                $primaryCert.ValidTo.ToString('yyyy-MM-dd HH:mm:ss') 
            } else { 
                "Unknown" 
            }

            # Safe property access with fallbacks
            $subjectText = if ($primaryCert.Subject) { $primaryCert.Subject } else { "Unknown Certificate" }

            $alertLines += @(
                "**{0}**" -f $subjectText
                "- **Status**: {0}" -f $statusText
                "- **Valid To**: {0}" -f $validToText
            )

            # Add location information
            if ($allLocations.Count -eq 0) {
                $alertLines += "- **Location**: *No location data available*"
            } elseif ($allLocations.Count -eq 1) {
                $formattedSingleLocation = Format-RepositoryPath -Path $allLocations[0]
                $alertLines += "- **Location**: " + $formattedSingleLocation
            } else {
                $alertLines += "- **Locations** ({0} total):" -f $allLocations.Count
                foreach ($location in $allLocations) {
                    $formattedLocation = Format-RepositoryPath -Path $location
                    $alertLines += "  - " + $formattedLocation
                }
            }

            # Debug: Log location processing for troubleshooting (console only)
            Write-Log -Message ("Processing locations for {0}: Raw instances={1}, Final locations={2}" -f $primaryCert.Subject, $subjectGroup.Group.Count, $allLocations.Count) -LogLevel "DEBUG"
            if ($allLocations.Count -gt 0) {
                Write-Log -Message ("First location for {0}: '{1}'" -f $primaryCert.Subject, $allLocations[0]) -LogLevel "DEBUG"
            } else {
                # Debug: Check what the raw AllLocations field contains
                foreach ($cert in $subjectGroup.Group) {
                    if ($cert.AllLocations) {
                        Write-Log -Message ("Raw AllLocations for {0}: '{1}' (Length: {2})" -f $primaryCert.Subject, $cert.AllLocations, $cert.AllLocations.Length) -LogLevel "DEBUG"
                    } else {
                        Write-Log -Message ("AllLocations is null or empty for {0}" -f $primaryCert.Subject) -LogLevel "DEBUG"
                    }
                }
            }

            # If multiple certificates exist for this subject, show count
            if ($subjectGroup.Group.Count -gt 1) {
                $alertLines += "- **Note**: {0} certificate instances found for this subject" -f $subjectGroup.Group.Count
            }

            # Add blank line after each certificate for better readability
            $alertLines += ""
        }

        if ($subjectGroups.Count -gt $Config.MaxCertificatesInAlert) {
            $remaining = $subjectGroups.Count - $Config.MaxCertificatesInAlert
            $alertLines += "...and {0} more certificate subjects in this category" -f $remaining
            $alertLines += ""
        }
    }

    # Handle certificates with blank alert levels separately - but only if they have useful data
    $blankAlertCerts = $certificates | Where-Object { [string]::IsNullOrEmpty($_.AlertLevel) -and -not [string]::IsNullOrEmpty($_.Subject) }
    if ($blankAlertCerts.Count -gt 0) {
        $alertLines += "UNKNOWN STATUS Certificates ({0})" -f $blankAlertCerts.Count
        $alertLines += ""
        $alertLines += "The following certificates could not be properly categorized:"
        
        foreach ($cert in $blankAlertCerts | Select-Object -First 5) {
            $subjectDisplay = if ($cert.Subject) { $cert.Subject } else { "Unknown" }
            $daysDisplay = if ($cert.DaysToExpiry) { $cert.DaysToExpiry } else { "Unknown" }
            $alertLines += "- **{0}**" -f $subjectDisplay
            $alertLines += "  Days to Expiry: {0}" -f $daysDisplay
            $alertLines += ""
        }
        
        if ($blankAlertCerts.Count -gt 5) {
            $alertLines += "...and {0} more certificates with unknown status" -f ($blankAlertCerts.Count - 5)
            $alertLines += ""
        }
    }
    
        # Add concise footer
        $alertLines += @(
            ""
            "---"
            "**Action Required:** Review and renew certificates expiring within {0} days" -f $Config.CriticalThreshold
        )
        
        return $alertLines -join "`n"
        
    } finally {
        # Restore original debug preference
        $DebugPreference = $originalDebugPreference
    }
}

function Send-WebhookAlert {
    param (
        [string]$message,
        [array]$certificates
    )
    
    try {
        Write-Log -Message ("Sending Teams notification to 'ProdSpt Certificate Notifications' webhook for {0} certificates" -f $certificates.Count) -LogLevel "INFO"
        
        # Determine alert level based on certificates (using any expired/critical certificates)
        $alertLevel = if ($certificates | Where-Object { $_.AlertLevel -eq 'EXPIRED' }) {
            'EXPIRED'
        } elseif ($certificates | Where-Object { $_.AlertLevel -eq 'CRITICAL' }) {
            'CRITICAL'
        } elseif ($certificates | Where-Object { $_.AlertLevel -eq 'WARNING' }) {
            'WARNING'
        } else {
            'INFO'
        }
        
        # Create summary data for additional info using unique subjects
        $totalCerts = $certificates.Count
        $uniqueSubjects = ($certificates | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
        $expiredSubjects = ($certificates | Where-Object { $_.AlertLevel -eq 'EXPIRED' } | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
        $criticalSubjects = ($certificates | Where-Object { $_.AlertLevel -eq 'CRITICAL' } | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
        $warningSubjects = ($certificates | Where-Object { $_.AlertLevel -eq 'WARNING' } | Group-Object Subject | Measure-Object | Select-Object -ExpandProperty Count)
        
        # Create clean summary data for technical reference
        $alertData = "Sources: {0} | Subjects: {1} | Records: {2}" -f $Config.CertSources.Count, $uniqueSubjects, $totalCerts
        if ($expiredSubjects -gt 0) { $alertData += " | Expired: {0}" -f $expiredSubjects }
        if ($criticalSubjects -gt 0) { $alertData += " | Critical: {0}" -f $criticalSubjects }
        if ($warningSubjects -gt 0) { $alertData += " | Warning: {0}" -f $warningSubjects }
        
        # Send notification using the stored procedure with concise title
        $alertTitle = if ($expiredSubjects -gt 0) {
            "URGENT: {0} Certificate(s) Expired" -f $expiredSubjects
        } elseif ($criticalSubjects -gt 0) {
            "CRITICAL: {0} Certificate(s) Expiring Soon" -f $criticalSubjects
        } else {
            "Certificate Alert: {0} Expiring" -f $uniqueSubjects
        }
        
        # Prepare structured certificate data for multiple sections
        $groupedCerts = $certificates | Group-Object Subject | Sort-Object @{Expression={$_.Group | ForEach-Object {$_.DaysToExpiry} | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum}}
        $certificateSections = @()
        
        foreach ($subjectGroup in $groupedCerts) {
            $primaryCert = $subjectGroup.Group | Sort-Object DaysToExpiry | Select-Object -First 1
            
            # Skip certificates with missing critical data
            if ([string]::IsNullOrEmpty($primaryCert.Subject) -or [string]::IsNullOrEmpty($primaryCert.Issuer)) {
                continue
            }
            
            $statusText = switch ($primaryCert.DaysToExpiry) {
                {$_ -lt 0} { "EXPIRED {0} days ago" -f [Math]::Abs($_) }
                0 { "EXPIRES TODAY" }
                default { "Expires in {0} days" -f $_ }
            }
            
            # Get all unique locations for this certificate
            $allLocations = @()
            foreach ($cert in $subjectGroup.Group) {
                if ($cert.AllLocations -and (-not [string]::IsNullOrWhiteSpace($cert.AllLocations))) {
                    $splitLocations = $cert.AllLocations -split '; '
                    foreach ($splitLocation in $splitLocations) {
                        $location = $splitLocation.Trim()
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
            }
            
            # Remove duplicates manually
            $uniqueLocations = @()
            foreach ($location in $allLocations) {
                if ($uniqueLocations -notcontains $location) {
                    $uniqueLocations += $location
                }
            }
            
            $validToText = if ($primaryCert.ValidTo) { 
                $primaryCert.ValidTo.ToString('yyyy-MM-dd HH:mm:ss') 
            } else { 
                "Unknown" 
            }
            
            # Build section text with proper line breaks - use markdown line breaks for Teams
            $sectionText = "**Status:** {0}  `n" -f $statusText
            $sectionText += "**Valid To:** {0}  `n" -f $validToText
            
            # Add unique thumbprints count if more than one instance
            if ($subjectGroup.Group.Count -gt 1) {
                $sectionText += "**Unique Thumbprints:** {0} found  `n" -f $subjectGroup.Group.Count
            }
            
            if ($uniqueLocations.Count -eq 0) {
                $sectionText += "**Location:** *No location data available*"
            } elseif ($uniqueLocations.Count -eq 1) {
                $formattedSingleLocation = Format-RepositoryPath -Path $uniqueLocations[0]
                $sectionText += "**Location:** {0}" -f $formattedSingleLocation
            } else {
                $sectionText += "**Locations** ({0} total):  `n" -f $uniqueLocations.Count
                foreach ($location in $uniqueLocations) {
                    $formattedLocation = Format-RepositoryPath -Path $location
                    $sectionText += "• {0}  `n" -f $formattedLocation
                }
                # Remove trailing newlines
                $sectionText = $sectionText.TrimEnd(" `n")
            }
            
            $certificateSections += "{0}|{1}" -f $primaryCert.Subject, $sectionText
        }
        
        # Convert certificate sections to pipe-delimited format for SQL
        $certificateDataString = ($certificateSections -join "||").Replace("'", "''")
        
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
"@ -f $alertTitle.Replace("'", "''"), $message.Replace("'", "''"), $alertLevel, $alertData.Replace("'", "''"), $certificateDataString

        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction Stop
        
        Write-Log -Message "'ProdSpt Certificate Notifications' Teams notification sent successfully via stored procedure" -LogLevel "INFO"
        return $true
        
    } catch {
        $errorMessage = "Failed to send 'ProdSpt Certificate Notifications' Teams notification: {0}" -f $_.Exception.Message
        Write-Log -Message $errorMessage -LogLevel "ERROR"
        Write-Log -Message "Failed alert message content:" -LogLevel "ERROR" -AdditionalInfo $message
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

    # Format and send alert
    $alertMessage = Format-AlertMessage -certificates $expiringCertificates
    
    if ($null -ne $alertMessage) {
        $teamsSuccess = Send-WebhookAlert -message $alertMessage -certificates $expiringCertificates
        
        if ($teamsSuccess) {
            Write-Log -Message ("'ProdSpt Certificate Notifications' Teams notification sent successfully for {0} certificates" -f $expiringCertificates.Count) -LogLevel "INFO"
        } else {
            Write-Log -Message "'ProdSpt Certificate Notifications' Teams notification failed" -LogLevel "ERROR"
        }
    } else {
        Write-Log -Message "No alert message generated" -LogLevel "WARNING"
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

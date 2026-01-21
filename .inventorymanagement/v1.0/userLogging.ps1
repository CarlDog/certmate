# Parameters
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory"
$Table = "userLogging"
$LogTable = "collectionLogs"
$RetentionDays = 90  # Number of days to keep log entries
$ScriptName = $Table # Ensure this is set for Write-Log

# Set error action preference to continue to avoid pipeline stopping
$ErrorActionPreference = 'Continue'

# Get user info from Active Directory
$UserNames = @("carl.yeager","theodore.henze","dillon.strable","dylan.guest","shane.cardwell") 

#region Functions
# Function: Write Log
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
    [LogId], 
    [Timestamp], 
    [ScriptName], 
    [LogLevel], 
    [Message],
    [AdditionalInfo]
) VALUES (
    '$logId', 
    '$dbTimestamp', 
    N'$escapedScriptName', 
    N'$escapedLogLevel', 
    N'$escapedMessage',
    NULL
)
"@
        } else {
            $escapedAdditionalInfo = $AdditionalInfo.Replace("'", "''")
            $query = @"
INSERT INTO [$LogTable] (
    [LogId], 
    [Timestamp], 
    [ScriptName], 
    [LogLevel], 
    [Message],
    [AdditionalInfo]
) VALUES (
    '$logId', 
    '$dbTimestamp', 
    N'$escapedScriptName', 
    N'$escapedLogLevel', 
    N'$escapedMessage',
    N'$escapedAdditionalInfo'
)
"@
        }
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction SilentlyContinue
    } catch {
        $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Output ("[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message)
    }
}
#endregion

foreach ($userId in $UserNames) {
    try {
        # First get the user from Active Directory to get the display name
        Write-Log -Message ("Processing user: {0}" -f $userId) -LogLevel "INFO"
        $User = Get-ADUser -Identity $userId -Properties LastLogon,LastLogonDate,LastLogonTimestamp,Name
        if ($User) {
            # Use the full display name for database queries
            $displayName = $User.Name
            Write-Log -Message ("User found: {0}" -f $displayName) -LogLevel "INFO"
            # Get the latest entry from the database for this user (if any)
            # Use traditional string escaping for SQL compatibility with older SQL Agent
            $escapedName = $displayName.Replace("'", "''")
            $getMostRecentQuery = @"
SELECT TOP 1 
    [LastLogon], 
    [LastLogonDate], 
    [LastLogonTimestamp],
    [LogEntryTimestamp]
FROM [$Table]
WHERE [Name] = N'$escapedName'
ORDER BY [LogEntryTimestamp] DESC
"@
            $lastEntry = $null
            try {
                Write-Log -Message ("Executing query to get most recent entry") -LogLevel "DEBUG"
                $lastEntry = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $getMostRecentQuery
                
                if ($lastEntry) {
                    Write-Log -Message ("Found previous entry from {0}" -f $lastEntry.LogEntryTimestamp) -LogLevel "INFO"
                } else {
                    Write-Log -Message ("No previous entry found") -LogLevel "INFO"
                }
            }
            catch {
                Write-Log -Message ("No previous entry found for {0} or error querying database: {1}" -f $displayName, $_.Exception.Message) -LogLevel "WARNING"
            }

            # Convert AD timestamps to standard DateTime objects
            try {
                $currentLastLogon = [DateTime]::FromFileTime($User.LastLogon)
                $currentLastLogonDate = $User.LastLogonDate
                $currentLastLogonTimestamp = [DateTime]::FromFileTime($User.LastLogonTimestamp)
                
                Write-Log -Message ("LastLogon for {0}: {1}" -f $userId, $currentLastLogon) -LogLevel "DEBUG"
                Write-Log -Message ("LastLogonDate for {0}: {1}" -f $userId, $currentLastLogonDate) -LogLevel "DEBUG"
                Write-Log -Message ("LastLogonTimestamp for {0}: {1}" -f $userId, $currentLastLogonTimestamp) -LogLevel "DEBUG"
            } catch {
                Write-Log -Message ("Error converting timestamps: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
                # Continue to next user instead of throwing
                continue
            }
            
            # Determine if anything has changed
            $needToInsert = $false
            $changeReason = ""
            
            if ($null -eq $lastEntry) {
                # No previous record, definitely insert
                $needToInsert = $true
                $changeReason = "First entry for this user"
            }
            else {
                # Compare each timestamp field (ignoring milliseconds)
                try {
                    # Handle possible null values in database
                    $dbLastLogon = if ($null -ne $lastEntry.LastLogon) { 
                        [DateTime]::Parse($lastEntry.LastLogon.ToString()) 
                    } else { 
                        [DateTime]::MinValue 
                    }
                    
                    $dbLastLogonDate = if ($null -ne $lastEntry.LastLogonDate) { 
                        [DateTime]::Parse($lastEntry.LastLogonDate.ToString()) 
                    } else { 
                        [DateTime]::MinValue 
                    }
                    
                    $dbLastLogonTimestamp = if ($null -ne $lastEntry.LastLogonTimestamp) { 
                        [DateTime]::Parse($lastEntry.LastLogonTimestamp.ToString()) 
                    } else { 
                        [DateTime]::MinValue 
                    }
                    
                    $lastEntryDate = [DateTime]::Parse($lastEntry.LogEntryTimestamp.ToString()).Date
                    
                    # Floor all dates to seconds for comparison (removes millisecond differences)
                    $currentLastLogonFloored = [DateTime]::new(
                        $currentLastLogon.Year, $currentLastLogon.Month, $currentLastLogon.Day,
                        $currentLastLogon.Hour, $currentLastLogon.Minute, $currentLastLogon.Second
                    )
                    $dbLastLogonFloored = [DateTime]::new(
                        $dbLastLogon.Year, $dbLastLogon.Month, $dbLastLogon.Day,
                        $dbLastLogon.Hour, $dbLastLogon.Minute, $dbLastLogon.Second
                    )
                    
                    $currentLastLogonDateFloored = if ($null -ne $currentLastLogonDate) {
                        [DateTime]::new(
                            $currentLastLogonDate.Year, $currentLastLogonDate.Month, $currentLastLogonDate.Day,
                            $currentLastLogonDate.Hour, $currentLastLogonDate.Minute, $currentLastLogonDate.Second
                        )
                    } else {
                        [DateTime]::MinValue
                    }
                    
                    $dbLastLogonDateFloored = [DateTime]::new(
                        $dbLastLogonDate.Year, $dbLastLogonDate.Month, $dbLastLogonDate.Day,
                        $dbLastLogonDate.Hour, $dbLastLogonDate.Minute, $dbLastLogonDate.Second
                    )
                    
                    $currentLastLogonTimestampFloored = [DateTime]::new(
                        $currentLastLogonTimestamp.Year, $currentLastLogonTimestamp.Month, $currentLastLogonTimestamp.Day,
                        $currentLastLogonTimestamp.Hour, $currentLastLogonTimestamp.Minute, $currentLastLogonTimestamp.Second
                    )
                    
                    $dbLastLogonTimestampFloored = [DateTime]::new(
                        $dbLastLogonTimestamp.Year, $dbLastLogonTimestamp.Month, $dbLastLogonTimestamp.Day,
                        $dbLastLogonTimestamp.Hour, $dbLastLogonTimestamp.Minute, $dbLastLogonTimestamp.Second
                    )
                    
                    # Check for changes
                    if ($currentLastLogonFloored -ne $dbLastLogonFloored) {
                        $needToInsert = $true
                        $changeReason += ("LastLogon changed from {0} to {1}; " -f $dbLastLogonFloored, $currentLastLogonFloored)
                    }
                    
                    if ($currentLastLogonDateFloored -ne $dbLastLogonDateFloored) {
                        $needToInsert = $true
                        $changeReason += ("LastLogonDate changed from {0} to {1}; " -f $dbLastLogonDateFloored, $currentLastLogonDateFloored)
                    }
                    
                    if ($currentLastLogonTimestampFloored -ne $dbLastLogonTimestampFloored) {
                        $needToInsert = $true
                        $changeReason += ("LastLogonTimestamp changed from {0} to {1}; " -f $dbLastLogonTimestampFloored, $currentLastLogonTimestampFloored)
                    }
                    
                    # Check if the last entry was today
                    $today = (Get-Date).Date
                    
                    if (-not $needToInsert -and $lastEntryDate -eq $today) {
                        Write-Log -Message ("User {0} already has an entry today and no changes detected." -f $displayName) -LogLevel "INFO"
                        continue
                    }
                }
                catch {
                    # Error comparing timestamps, just log the current state
                    $needToInsert = $true
                    $changeReason = ("Error comparing timestamps: {0}" -f $_.Exception.Message)
                    Write-Log -Message $changeReason -LogLevel "WARNING"
                }
            }
            
            # If we need to insert, do so
            if ($needToInsert) {                try {
                    $logEntryId = [System.Guid]::NewGuid().ToString()
                    $logEntryTimestamp = Get-Date
                    $logEntryTimestampStr = $logEntryTimestamp.ToString('yyyy-MM-dd HH:mm:ss')
                    
                    # Format datetime values with second precision
                    $lastLogonStr = $currentLastLogon.ToString('yyyy-MM-dd HH:mm:ss')
                    $lastLogonTimestampStr = $currentLastLogonTimestamp.ToString('yyyy-MM-dd HH:mm:ss')
                    
                    # Properly escape the display name for SQL
                    $escapedName = $displayName.Replace("'", "''")
                    
                    # Create different query if LastLogonDate is NULL
                    if ($null -eq $currentLastLogonDate) {
                        $insertQuery = @"
INSERT INTO [$Table] (
    [LogEntryId], 
    [LogEntryTimestamp], 
    [Name], 
    [LastLogon], 
    [LastLogonDate], 
    [LastLogonTimestamp], 
    [MachineName]
) VALUES (
    N'$logEntryId', 
    '$logEntryTimestampStr', 
    N'$escapedName', 
    '$lastLogonStr', 
    NULL, 
    '$lastLogonTimestampStr', 
    N'Active Directory'
)
"@
                    } else {
                        $lastLogonDateStr = $currentLastLogonDate.ToString('yyyy-MM-dd HH:mm:ss')
                        $insertQuery = @"
INSERT INTO [$Table] (
    [LogEntryId], 
    [LogEntryTimestamp], 
    [Name], 
    [LastLogon], 
    [LastLogonDate], 
    [LastLogonTimestamp], 
    [MachineName]
) VALUES (
    N'$logEntryId', 
    '$logEntryTimestampStr', 
    N'$escapedName', 
    '$lastLogonStr', 
    '$lastLogonDateStr', 
    '$lastLogonTimestampStr', 
    N'Active Directory'
)
"@
                    }
                    
                    Write-Log -Message ("Executing insert query for {0}" -f $displayName) -LogLevel "DEBUG"
                    Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $insertQuery
                    Write-Log -Message ("Inserted new entry for {0}: {1}" -f $displayName, $changeReason) -LogLevel "INFO"
                } catch {
                    Write-Log -Message ("Error inserting data: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
                }
            }
            else {
                Write-Log -Message ("No changes detected for {0}, skipping insert" -f $displayName) -LogLevel "INFO"
            }
        }
        else {
            Write-Log -Message ("User {0} not found in Active Directory." -f $userId) -LogLevel "WARNING"
        }
    }
    catch {
        Write-Log -Message ("ERROR processing {0}: {1}" -f $userId, $_.Exception.Message) -LogLevel "ERROR"
    }
}

# Clean up old entries based on retention policy
try {
    $cleanupQuery = "DELETE FROM [$Table] WHERE [LogEntryTimestamp] < DATEADD(day, -$RetentionDays, GETDATE())"
    Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $cleanupQuery
    Write-Log -Message ("Cleaned up user log entries older than {0} days" -f $RetentionDays) -LogLevel "INFO"
} catch {
    Write-Log -Message ("ERROR during cleanup: {0}" -f $_.Exception.Message) -LogLevel "ERROR"
}

# =====================
# Global Parameters & Variables
# =====================
param(
    [string]$Server = "TST-SQL-INT2",
    [string]$Database = "ProdSpt_Inventory",
    [string]$Table = "f5Nodes",
    [string]$ScriptName = $Table,
    [string]$LogTable = "collectionLogs"
)

$ErrorActionPreference = 'Continue'

# =====================
# Functions
# =====================
function Write-Log {
    param(
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
            $query = (
                "INSERT INTO [{0}] ([LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]) " +
                "VALUES ('{1}', '{2}', N'{3}', N'{4}', N'{5}', NULL)"
            ) -f $LogTable, $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage
        } else {
            $escapedAdditionalInfo = $AdditionalInfo.Replace("'", "''")
            $query = (
                "INSERT INTO [{0}] ([LogId], [Timestamp], [ScriptName], [LogLevel], [Message], [AdditionalInfo]) " +
                "VALUES ('{1}', '{2}', N'{3}', N'{4}', N'{5}', N'{6}')"
            ) -f $LogTable, $logId, $dbTimestamp, $escapedScriptName, $escapedLogLevel, $escapedMessage, $escapedAdditionalInfo
        }
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query -ErrorAction SilentlyContinue
    } catch {
        $errorTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Output ("[{0}] WARNING: Failed to write to log database: {1}" -f $errorTime, $_.Exception.Message)
    }
}

# =====================
# Main Script Logic
# =====================
try {
    Write-Log -Message ("Starting F5 node status update script execution") -LogLevel "INFO"
    Write-Log -Message ("Running as user: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogLevel "INFO"

    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $updated = 0
    $query = "SELECT Node FROM [{0}]" -f $Table
    $nodes = Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $query

    foreach ($row in $nodes) {
        $nodeName = $row.Node
        $isActive = 0
        $ipAddress = $null
        $dnsSuccess = $false
        $adSuccess = $false
        # Try DNS first
        try {
            $dnsResult = Resolve-DnsName -Name $nodeName -ErrorAction SilentlyContinue | Where-Object { $_.QueryType -eq 'A' }
            if ($dnsResult) {
                if ($dnsResult.IPAddress -is [System.Array]) {
                    $ipAddress = $dnsResult.IPAddress[0]
                } else {
                    $ipAddress = $dnsResult.IPAddress
                }
                Write-Log -Message ("DNS lookup for {0} returned IP: {1}" -f $nodeName, $ipAddress) -LogLevel "INFO"
                # Try to ping the IP
                try {
                    $pingResult = $false
                    if ($ipAddress) {
                        $pingResult = Test-Connection -ComputerName $ipAddress -Count 1 -Quiet
                        Write-Log -Message ("Ping result for {0} (IP: {1}): {2}" -f $nodeName, $ipAddress, $pingResult) -LogLevel "INFO"
                    }
                    if ($pingResult) {
                        $isActive = 1
                        $dnsSuccess = $true
                    } else {
                        Write-Log -Message ("Ping failed for {0} (IP: {1}) after DNS lookup." -f $nodeName, $ipAddress) -LogLevel "WARNING"
                    }
                } catch {
                    Write-Log -Message ("Ping threw exception for {0} (IP: {1}): {2}" -f $nodeName, $ipAddress, $_.Exception.Message) -LogLevel "WARNING"
                }
            } else {
                Write-Log -Message ("DNS lookup failed for {0}." -f $nodeName) -LogLevel "WARNING"
            }
        } catch {
            Write-Log -Message ("DNS lookup threw exception for {0}: {1}" -f $nodeName, $_.Exception.Message) -LogLevel "WARNING"
        }
        # If DNS fails, try AD
        if (-not $dnsSuccess) {
            try {
                $adResult = Get-ADComputer -Filter ("DNSHostName -eq '{0}'" -f $nodeName) -Properties IPv4Address -ErrorAction SilentlyContinue
                if ($null -ne $adResult -and $adResult -isnot [System.Array]) {
                    $adSuccess = $true
                    if ($adResult.IPv4Address -is [System.Array]) {
                        $ipAddress = $adResult.IPv4Address[0]
                    } else {
                        $ipAddress = $adResult.IPv4Address
                    }
                } elseif ($adResult -is [System.Array] -and $adResult.Count -gt 0) {
                    $adSuccess = $true
                    $first = $adResult[0]
                    if ($first.IPv4Address -is [System.Array]) {
                        $ipAddress = $first.IPv4Address[0]
                    } else {
                        $ipAddress = $first.IPv4Address
                    }
                }
                if ($adSuccess) {
                    Write-Log -Message ("AD lookup for {0} returned IP: {1}" -f $nodeName, $ipAddress) -LogLevel "INFO"
                    $isActive = 1
                } else {
                    Write-Log -Message ("AD lookup failed for {0}." -f $nodeName) -LogLevel "WARNING"
                }
            } catch {
                Write-Log -Message ("AD lookup threw exception for {0}: {1}" -f $nodeName, $_.Exception.Message) -LogLevel "WARNING"
            }
        }
        if (-not $dnsSuccess -and -not $adSuccess) {
            Write-Log -Message ("Node {0} is inactive: DNS+ping and AD both failed." -f $nodeName) -LogLevel "WARNING"
        }
        Write-Log -Message ("Final isActive for {0}: {1}" -f $nodeName, $isActive) -LogLevel "INFO"
        $escapedNode = $nodeName.Replace("'", "''")
        $escapedIP = if ($ipAddress) { $ipAddress.Replace("'", "''") } else { $null }
        $upQuery = (
            "UPDATE [{0}] SET IPAddress = N'{1}', IsActive = {2}, LastSeen = '{3}' WHERE Node = N'{4}'"
        ) -f $Table, $escapedIP, $isActive, $now, $escapedNode
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $upQuery
        $updated++
    }
    Write-Log -Message ("Updated {0} F5 nodes in the database." -f $updated) -LogLevel "INFO"
    Write-Log -Message ("F5 node status update script completed successfully") -LogLevel "INFO"
} catch {
    $errorMessage = 'ERROR: {0}`nStackTrace: {1}' -f $_.Exception.Message, $_.ScriptStackTrace
    Write-Log -Message $errorMessage -LogLevel "ERROR"
    Write-Log -Message ("F5 node status update script failed with errors") -LogLevel "ERROR"
} finally {
    Write-Log -Message ("Script execution completed at {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -LogLevel "INFO"
}

# Minimal F5 Token Test Script

# =====================
# Global Parameters
# =====================
$Server = "TST-SQL-INT2"
$Database = "ProdSpt_Inventory" 
$LogTable = "collectionLogs"
$ScriptName = "test-f5-token"
$ErrorActionPreference = 'Continue'

# Credential Management
$UserName = "svc.prod.maint" # The service account with LTM read access
$Password = "REDACTED_F5_PASSWORD" 
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($UserName, $SecurePassword)

Add-Type -AssemblyName System.Web

# =====================
# Bypass SSL/TLS certificate validation for all .NET requests (for testing only, SQL Agent compatible)
# =====================
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

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

function Invoke-RestMethodOverride {
    [cmdletBinding(DefaultParameterSetName='Anonymous')]
    param (
        [Parameter(Mandatory=$true)][Microsoft.PowerShell.Commands.WebRequestMethod]$Method,
        [Parameter(Mandatory=$true)][uri]$URI,
        [System.Management.Automation.PSCredential]$Credential,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession=(New-Object Microsoft.PowerShell.Commands.WebRequestSession),
        $Body,
        $Headers,
        $ContentType
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Invoke-RestMethod @PSBoundParameters -SkipCertificateCheck
    } else {
        Invoke-RestMethod @PSBoundParameters
    }
}

function New-F5Session {
    [cmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$LTMName,
        [System.Management.Automation.PSCredential]$Credential = $null
    )
    $LTMCredentials = $Credential
    Write-Log -Message ("DEBUG: New-F5Session using credentials: {0}" -f $LTMCredentials.UserName)
    $AuthURL = ("https://{0}/mgmt/shared/authn/login" -f $LTMName)
    $JSONBody = @{username = $LTMCredentials.username; password=$LTMCredentials.GetNetworkCredential().password; loginProviderName='tmos'} | ConvertTo-Json
    try {
        $Result = Invoke-RestMethodOverride -Method POST -Uri $AuthURL -Body $JSONBody -Credential $LTMCredentials -ContentType 'application/json'
        Write-Log -Message ("DEBUG: Raw token object returned: {0}" -f ($Result | ConvertTo-Json -Compress))
        $Token = $Result.token.token
        Write-Log -Message ("SUCCESS: Got F5 token for {0}: {1}" -f $LTMName, $Token)
        return $Token
    } catch {
        Write-Log -Message ("ERROR: Exception getting F5 token for {0}: {1}" -f $LTMName, $_) -LogLevel "ERROR"
        return $null
    }
}

# Main Test Logic
try {
    $TestNode = "wau-f5g01-mgmt.us.cambridge"  # Change to a known F5 node
    Write-Log -Message ("Testing F5 connection to {0}" -f $TestNode)
    $Token = New-F5Session -LTMName $TestNode -Credential $Credential
    if ($Token) {
        Write-Log -Message ("Token retrieval successful: {0}" -f $Token)
    } else {
        Write-Log -Message ("Token retrieval failed.")
    }
} catch {
    Write-Log -Message ("ERROR: Exception in test connection: {0}" -f $_) -LogLevel "ERROR"
}

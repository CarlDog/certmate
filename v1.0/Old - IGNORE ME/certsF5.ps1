## F5 Certificate Collection Script v2.1
## Written by: Carl R. Yeager
## Last Updated: 10052024

Import-Module -Name "F5-LTM" -ErrorAction Stop

$scriptDir = if ($PSISE) { ($PSISE.CurrentFile.FullPath).Replace(('\{0}' -f ($MyInvocation.MyCommand).Name),'') } else { ($script:MyInvocation.MyCommand.Path).Replace(('\{0}' -f ($MyInvocation.MyCommand).Name),'') }
$textColor_error, $textColor_warn = 'Red', 'Yellow'
$skipCerts, $skipCSV, $skipCopy = $false, $false, $true

$f5Nodes = @{
    "f5-dev-mgmt.us.cambridge" = @("f5-dg01-mgmt.us.cambridge","f5-dg02-mgmt.us.cambridge")
    "f5-cir-int" = @("f5-g01-mgmt.us.cambridge","f5-g02-mgmt.us.cambridge")
    "f5-cir-ext" = @("f5-g03-mgmt.us.cambridge","f5-g04-mgmt.us.cambridge")
    "f5-wau-int.us.cambridge" = @("f5-wau-g01-mgmt.us.cambridge","f5-wau-g02-mgmt.us.cambridge")
    "f5-wau-ext.us.cambridge" = @("f5-wau-g03-mgmt.us.cambridge","f5-wau-g04-mgmt.us.cambridge")
    "f5-gil-int.us.cambridge" = @("gil-f5g01-mgmt.us.cambridge","gil-f5g02-mgmt.us.cambridge")
    "f5-gil-ext.us.cambridge" = @("gil-f5g03-mgmt.us.cambridge","gil-f5g04-mgmt.us.cambridge")
}
$exportFile = '{0}\Exports\certsF5.csv' -f $scriptDir
$sharedDir = '\\cir\files\Shared\ProductionSupport\Inventory Management'

$mycreds = if ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -notmatch '^(adm|svc)\.') {
    Get-Credential -Message "Enter your ADM credentials"
} else {
    [System.Management.Automation.PSCredential]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().Name, (ConvertTo-SecureString -String "" -AsPlainText -Force))
}

# Ensure directories exist
foreach ($dir in @($exportFile, $sharedDir)) { 
    if (-not (Test-Path -Path $dir)) { 
        Write-Host -Object ("Creating directory: {0}" -f $dir)
        New-Item -Path $dir -ItemType Directory -Force 
    }
}

$CERTIFICATE_OBJECT_TEMPLATE = {
    param ($certificate, $filePath, $fileExtension, $sslProfiles, $f5Node)
    [pscustomobject]@{
        FilePath      = $filePath
        FileExtension = $fileExtension
        Subject       = $certificate.Subject
        Issuer        = $certificate.Issuer
        Thumbprint    = $certificate.Thumbprint
        ValidFrom     = $certificate.NotBefore
        ValidTo       = $certificate.NotAfter
        SslProfiles   = $sslProfiles
        f5Node        = $f5Node
    }
}

function Format-Certificate {
    param ($certificate, $filePath, $fileExtension, $sslProfiles, $f5Node)
    & $CERTIFICATE_OBJECT_TEMPLATE -certificate $certificate -filePath $filePath -fileExtension $fileExtension -sslProfiles $sslProfiles -f5Node $f5Node
}

function Get-CertificateMetadata {
    $certificates = @()
    $uniqueThumbprints = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($nodeKey in $f5Nodes.Keys) {
        foreach ($subNode in $f5Nodes[$nodeKey]) {
            Write-Host -Object ("Processing node: {0}" -f $subNode)
            try {
                $f5Session = New-F5Session -LTMName $subNode -LTMCredentials $mycreds -ErrorAction Stop -PassThru $true
                if ($null -eq $f5Session) {
                    Write-Host -ForegroundColor Yellow -Object "Failed to create session for $subNode"
                    continue
                }

                Write-Host -Object ("Fetching SSL profiles for node: {0}" -f $subNode)
                $sslProfiles = Get-F5SSLProfile -Session $f5Session -ErrorAction Stop
                if ($null -eq $sslProfiles) {
                    Write-Host -ForegroundColor Yellow -Object "Failed to get SSL profiles for $subNode"
                    continue
                }

                foreach ($profile in $sslProfiles) {
                    Write-Host -Object ("Fetching certificates for profile: {0} on node: {1}" -f $profile.Name, $subNode)
                    $sslCerts = Get-F5Certificate -Session $f5Session -Name $profile.Name -ErrorAction Stop
                    if ($null -eq $sslCerts) {
                        Write-Host -ForegroundColor Yellow -Object "Failed to get certificates for profile $($profile.Name) on $subNode"
                        continue
                    }

                    foreach ($certificate in $sslCerts) {
                        if ($uniqueThumbprints.Add($certificate.Thumbprint)) {
                            $certificates += Format-Certificate -certificate $certificate -filePath $profile.FullPath -fileExtension ".crt" -sslProfiles @($profile.Name) -f5Node $subNode
                        }
                    }
                }
                Write-Host -Object ("Disconnecting session for node: {0}" -f $subNode)
                Disconnect-F5LTM -Session $f5Session -ErrorAction Stop
            } catch {
                Write-Host -ForegroundColor Yellow -Object ('ERROR: {0}' -f $_.Exception.Message)
            }
        }
    }
    return $certificates
}

function New-F5Session {
    param ($LTMName, $LTMCredentials, $Default, $PassThru, $TokenLifespan=1200)
    $BaseURL = "https://$LTMName/"
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $AuthURL = "https://$LTMName/mgmt/shared/authn/login"
    $JSONBody = @{username = $LTMCredentials.username; password=$LTMCredentials.GetNetworkCredential().password; loginProviderName='tmos'} | ConvertTo-Json

    try {
        Write-Host -Object ("Creating session for LTM: {0}" -f $LTMName)
        $Result = Invoke-RestMethodOverride -Method POST -Uri $AuthURL -Body $JSONBody -Credential $LTMCredentials -ContentType 'application/json'
        $Token = $Result.token.token
        $session.Headers.Add('X-F5-Auth-Token', $Token)
        $TokenReference = if ($Result.token.uuid) { $Result.token.uuid } else { $Result.token.name }
        if ($TokenLifespan -ne 1200) {
            $Body = @{ timeout = $TokenLifespan } | ConvertTo-Json
            $Headers = @{ 'X-F5-Auth-Token' = $Token }
            Invoke-RestMethodOverride -Method Patch -Uri https://$LTMName/mgmt/shared/authz/tokens/$TokenReference -Headers $Headers -Body $Body -WebSession $session | Out-Null
        }
        $ts = New-TimeSpan -Minutes ($TokenLifespan/60)
        $date = Get-Date -Date $Result.token.startTime
        $ExpirationTime = $date + $ts
        $session.Headers.Add('Token-Expiration', $ExpirationTime)
    } catch {
        try {
            Invoke-WebRequest -Uri $BaseURL -ErrorVariable LTMError -TimeoutSec 3
        } catch {
            if ($LTMError[0] -notmatch 'Unauthorized') { Throw ("The specified LTM name $LTMName is not valid.") }
        }
        Write-Verbose "The version must be prior to 11.6 since we failed to retrieve an auth token."
        $Credential = $LTMCredentials
    }

    $newSession = [pscustomobject]@{
        Name       = $LTMName
        BaseURL    = $BaseURL
        Credential = $Credential
        WebSession = $session
        Token      = $Token
    } | Add-Member -Name GetLink -MemberType ScriptMethod { param($Link) $Link -replace 'localhost', $this.Name } -PassThru

    $VersionURL = $BaseURL + 'mgmt/tm/sys/version/'
    $JSON = Invoke-F5RestMethod -Method Get -Uri $VersionURL -F5Session $newSession | ConvertTo-Json -Depth 10
    $version = if ($JSON -match '(\d+\.?){3,4}') { [Regex]::Match($JSON,'(\d+\.?){3,4}').Value } else { '0.0.0.0' }
    $newSession | Add-Member -Name LTMVersion -Value ([Version]$version) -MemberType NoteProperty

    if ($Default -or !($Script:F5Session)) { $Script:F5Session = $newSession }
    if ($PassThru) { $newSession }
}

function Get-F5SSLProfile {
    param ($F5Session=$Script:F5Session, [string]$UUID)
    Test-F5Session($F5Session)
    for ($i=0; $i -lt $UUID.Count; $i++) {
        $id = $UUID[$i]
        $URI = $F5Session.BaseURL + ('mgmt/tm/ltm/profile/client-ssl/{0}' -f $id)
        $JSON = Invoke-F5RestMethod -Method Get -Uri $URI -F5Session $F5Session
        $JSON = Resolve-NestedStats -F5Session $F5Session -JSONData $JSON
        Invoke-NullCoalescing {$JSON.entries} {$JSON} | Add-ObjectDetail
    }
}

function Get-F5Certificate {
    param ($F5Session=$Script:F5Session, [string]$UUID)
    Test-F5Session($F5Session)
    for ($i=0; $i -lt $UUID.Count; $i++) {
        $id = $UUID[$i]
        $URI = $F5Session.BaseURL + ('mgmt/cm/adc-core/working-config/sys/file/ssl-cert/{0}' -f $id)
        $JSON = Invoke-F5RestMethod -Method Get -Uri $URI -F5Session $F5Session
        $JSON = Resolve-NestedStats -F5Session $F5Session -JSONData $JSON
        Invoke-NullCoalescing {$JSON.entries} {$JSON} | Add-ObjectDetail
    }
}

function Invoke-F5RestMethod {
    param ($Method, $Uri, $F5Session, $Body)
    $webRequest = [System.Net.HttpWebRequest]::Create($Uri)
    $webRequest.Method = $Method
    $webRequest.ContentType = "application/json"
    $webRequest.Headers["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $F5Session.Credential.UserName, $F5Session.Credential.GetNetworkCredential().Password)))

    if ($Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        $byteArray = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $webRequest.ContentLength = $byteArray.Length
        $dataStream = $webRequest.GetRequestStream()
        $dataStream.Write($byteArray, 0, $byteArray.Length)
        $dataStream.Close()
    }

    try {
        $webResponse = $webRequest.GetResponse()
        $streamReader = [System.IO.StreamReader]::new($webResponse.GetResponseStream())
        $responseBody = $streamReader.ReadToEnd()
        $streamReader.Close()
        $webResponse.Close()
        return $responseBody | ConvertFrom-Json
    } catch {
        Write-Error "Error making REST API call: $_"
    }
}

try {
    $debugOptions = Get-Variable -Name $(Get-Variable | Where-Object { $_.Name -like 'skip*' }).Name -ValueOnly | Where-Object { $_.Value -eq $true }
    if ($debugOptions) {
        Write-Host -Object 'DEBUG OPTIONS: ' -NoNewline
        Write-Host -ForegroundColor $textColor_warn -Object ($debugOptions.Name -join ', ')
    }

    if (!$skipCerts) {
        Write-Host -Object 'Starting certificate metadata collection...'
        $certificates = Get-CertificateMetadata
        Write-Host -Object 'Certificate metadata collection completed.'
    }
    
    if (!$skipCSV) {
        Write-Host -Object 'Exporting collection results to CSV file(s) ...'
        if ($certificates) {
            Write-Host -Object ("`tExporting {0} ..." -f $exportFile)
            $certificates | Export-Csv -Path $exportFile -Force -NoTypeInformation
            Write-Host -Object 'CSV export completed.'
        } else {
            Write-Host -ForegroundColor $textColor_warn -Object ("`tNo certificate objects found to export ...")
        }
    }

    if (!$skipCopy) {
        Write-Host -Object ('Copying CSV files to {0} ...' -f $sharedDir)
        $sourceFiles = Get-ChildItem -Path $exportDir -File -Filter *.csv
        foreach ($file in $sourceFiles) {
            Write-Host -Object ("`tCopying {0} ..." -f $file.FullName)
            Copy-Item -Path $file.FullName -Destination $sharedDir -Force
        }
        Write-Host -Object 'CSV file copy completed.'
    }
} catch {
    Write-Host -ForegroundColor $textColor_error -Object ('ERROR: {0}' -f $_.Exception.Message)
}
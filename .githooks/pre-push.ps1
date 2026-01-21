#requires -Version 7.0
$ErrorActionPreference = 'Stop'

param(
    [string]$RemoteName,
    [string]$RemoteUrl
)

if (-not $PSBoundParameters.ContainsKey('RemoteName')) {
    if ($args.Count -ge 1) { $RemoteName = $args[0] }
}
if (-not $PSBoundParameters.ContainsKey('RemoteUrl')) {
    if ($args.Count -ge 2) { $RemoteUrl = $args[1] }
}

if ($RemoteName -ne 'origin') {
    Write-Host "[pre-push] Blocked: push to '$RemoteName'. Use 'origin' to mirror to GitHub + Azure DevOps." -ForegroundColor Yellow
    Write-Host "           Try: git push origin $(git branch --show-current)"
    exit 1
}

$githubUrl = 'https://github.com/CarlDog-Cambridge/InventoryManagement.git'
$azdoUrl = 'https://dev.azure.com/Cambridge-Technology/ProductionSupport/_git/InventoryManagement'

$pushUrls = git config --get-all remote.origin.pushurl 2>$null
if (-not $pushUrls) { $pushUrls = @() }

if (-not ($pushUrls -match 'github\.com')) {
    Write-Host "[pre-push] Adding GitHub pushurl to origin"
    git remote set-url --add --push origin $githubUrl | Out-Null
}
if (-not ($pushUrls -match 'dev\.azure\.com')) {
    Write-Host "[pre-push] Adding Azure DevOps pushurl to origin"
    git remote set-url --add --push origin $azdoUrl | Out-Null
}

Write-Host "[pre-push] Mirroring via 'origin' confirmed. Proceeding with push..."
exit 0

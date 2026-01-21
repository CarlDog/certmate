# Sets the repository to use versioned hooks from .githooks
param(
    [switch]$Global
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
if (-not (Test-Path "$repoRoot/.githooks")) {
    Write-Error ".githooks directory not found at $repoRoot/.githooks"
    exit 1
}

if ($Global) {
    git config --global core.hooksPath (Join-Path $repoRoot ".githooks")
    Write-Host "Configured global core.hooksPath to .githooks in this repo."
}
else {
    git config core.hooksPath .githooks
    Write-Host "Configured core.hooksPath for this repo to .githooks"
}

Write-Host "Ensuring LF endings for hooks (git will enforce via .gitattributes)."

# Ensure pushes default to current branch (simplifies 'git push')
try {
    git config push.default current
    Write-Host "Configured 'push.default' to 'current' for this repo."
}
catch {
    Write-Warning "Could not set 'push.default'. You can set manually: git config push.default current"
}

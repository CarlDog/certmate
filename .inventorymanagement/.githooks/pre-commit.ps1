#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Write-Host "[pre-commit] Restoring tools and solution..."
& dotnet tool restore | Out-Null
& dotnet restore

Write-Host "[pre-commit] Formatting check (dotnet-format)..."
try {
    & dotnet dotnet-format --check
}
catch {
    Write-Error "[pre-commit] Formatting issues found. Run: dotnet tool run dotnet-format"
    exit 1
}

Write-Host "[pre-commit] Building..."
& dotnet build --nologo

Write-Host "[pre-commit] Running tests..."
& dotnet test --nologo --no-build --verbosity minimal --logger "trx;LogFileName=test-results.trx"

Write-Host "[pre-commit] All checks passed."

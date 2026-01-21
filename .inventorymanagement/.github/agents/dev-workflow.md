# Development Workflow Agent

You are a **Development Workflow specialist** for the Cambridge Inventory Management system. Your expertise is in common development tasks, build/test/deploy workflows, and development environment setup.

## Your Core Responsibilities

1. **Build & Test**: Execute dotnet build, test, and restore commands
2. **Code Quality**: Run code formatting, linting, and static analysis
3. **Git Workflow**: Branch management, commit conventions, PR templates
4. **Local Development**: Setup dev environment, user secrets, local SQL
5. **Troubleshooting**: Diagnose build errors, test failures, runtime issues

## Quick Commands Reference

### Build & Restore

```powershell
# Restore NuGet packages
dotnet restore

# Build entire solution
dotnet build --nologo

# Build specific project
dotnet build src/Domain/Domain.csproj --nologo

# Clean build artifacts
dotnet clean
```

### Testing

```powershell
# Run all tests
dotnet test --nologo

# Run tests with coverage
dotnet test --collect:"XPlat Code Coverage" --nologo

# Run specific test project
dotnet test tests/Domain.Tests/Domain.Tests.csproj --nologo

# Run specific test by name
dotnet test --filter "FullyQualifiedName~CertificateNormalizerTests" --nologo

# Run tests by category
dotnet test --filter "Category=Integration" --nologo
```

### Code Formatting

```powershell
# Check formatting (dry run)
dotnet format --verify-no-changes

# Apply formatting
dotnet format

# Format specific project
dotnet format src/Domain/Domain.csproj
```

### Run the Agent Service

```powershell
# Run locally with Development environment
dotnet run --project src/Agent/Agent.csproj --environment Development

# Run with specific configuration
dotnet run --project src/Agent/Agent.csproj --configuration Release

# Watch mode (auto-restart on file changes)
dotnet watch --project src/Agent/Agent.csproj
```

## VS Code Tasks

Use the pre-configured tasks in `.vscode/tasks.json`:

```json
// Use Ctrl+Shift+P → "Tasks: Run Task" → Select task

// Available tasks:
- "dotnet restore" → Restore NuGet packages
- "dotnet build" → Build solution
- "dotnet test" → Run all tests
- "dotnet format (check)" → Verify code formatting
- "pre-commit-check" → Full validation (restore → build → format → test)
```

**Keyboard shortcuts:**

-   `Ctrl+Shift+B` → Run build task
-   `Ctrl+Shift+T` → Run test task (if configured)

## Development Environment Setup

### Prerequisites

```powershell
# Check .NET version (requires .NET 9.0+)
dotnet --version

# Check PowerShell version (requires PowerShell 5.1+ or PowerShell 7+)
$PSVersionTable.PSVersion

# Verify SQL Server connectivity
Test-Connection -ComputerName localhost -Port 1433

# Check WinRM configuration
winrm get winrm/config
```

### Initial Setup

```powershell
# 1. Clone repository
git clone https://github.com/CarlDog-Cambridge/InventoryManagement.git
cd InventoryManagement

# 2. Restore packages
dotnet restore

# 3. Build solution
dotnet build

# 4. Run tests to verify
dotnet test

# 5. Setup user secrets for local development
dotnet user-secrets init --project src/Agent/Agent.csproj
dotnet user-secrets set "ConnectionStrings:InventoryDb" "Server=localhost;Database=CertInventory;Trusted_Connection=True;" --project src/Agent/Agent.csproj
dotnet user-secrets set "AzureKeyVault:VaultUri" "https://your-keyvault.vault.azure.net/" --project src/Agent/Agent.csproj
```

### SQL Server Setup (Local Development)

**Option 1: Docker/Testcontainers** (Recommended for testing)

```powershell
# Pull SQL Server 2022 image
docker pull mcr.microsoft.com/mssql/server:2022-latest

# Run SQL Server container
docker run -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=DevPassword123!" `
    -p 1433:1433 --name sqlserver-dev `
    -d mcr.microsoft.com/mssql/server:2022-latest

# Deploy schema
sqlcmd -S localhost -U sa -P "DevPassword123!" -i src/Infrastructure/Persistence/Schema/001-initial-schema.sql
sqlcmd -S localhost -U sa -P "DevPassword123!" -i src/Infrastructure/Persistence/Schema/002-table-valued-parameters.sql
```

**Option 2: LocalDB** (Windows only)

```powershell
# Create LocalDB instance
sqllocaldb create "CertInventoryDev" -s

# Deploy schema
sqlcmd -S "(localdb)\CertInventoryDev" -i src/Infrastructure/Persistence/Schema/001-initial-schema.sql
```

**Option 3: Full SQL Server Installation**

-   Use existing SQL Server instance
-   Create database: `CREATE DATABASE CertInventory;`
-   Deploy schema from `src/Infrastructure/Persistence/Schema/` files

## Git Workflow

### Branch Naming Convention

```
feature/short-description    → New features (e.g., feature/winrm-collector)
bugfix/short-description     → Bug fixes (e.g., bugfix/thumbprint-validation)
hotfix/short-description     → Production hotfixes (e.g., hotfix/sql-timeout)
docs/short-description       → Documentation only (e.g., docs/update-adr)
refactor/short-description   → Code refactoring (e.g., refactor/simplify-domain)
test/short-description       → Test additions (e.g., test/integration-coverage)
```

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Examples:**

```
feat(domain): add Certificate entity with validation

Implements Certificate aggregate root with:
- Thumbprint normalization (uppercase, no delimiters)
- ValidTo > ValidFrom validation
- SANs extraction for wildcards

Closes #12

---

fix(infra): retry policy for transient SQL errors

Adds Polly retry policy for SQL transient errors:
- 3 retries with exponential backoff
- Handles error codes: 40197, 40501, 40613, etc.

Fixes #45

---

test(application): add integration tests for CollectionOrchestrator

Covers:
- Multi-machine sequential harvest
- Concurrency limiting with semaphore
- Error handling for failed machines

Closes #67

---

docs(architecture): update ADR-002 with hexagonal justification

Clarifies rationale for full 7-project structure based on
Phase 3 WebUI requirements and feature expansion roadmap.
```

**Commit types:**

-   `feat`: New feature
-   `fix`: Bug fix
-   `docs`: Documentation only
-   `test`: Test additions/changes
-   `refactor`: Code refactoring (no behavior change)
-   `perf`: Performance improvement
-   `chore`: Maintenance tasks (dependencies, build config)

### Pull Request Workflow

```powershell
# 1. Create feature branch
git checkout -b feature/winrm-collector

# 2. Make changes and commit
git add .
git commit -m "feat(infra): implement WinRmOSCollector"

# 3. Push to remote
git push origin feature/winrm-collector

# 4. Create PR on GitHub
# - Use PR template (.github/PULL_REQUEST_TEMPLATE.md)
# - Link to issue(s)
# - Request reviewers
# - Add labels

# 5. Address review feedback
git add .
git commit -m "fix(infra): address PR feedback"
git push origin feature/winrm-collector

# 6. Merge after approval
# - Use "Squash and merge" for clean history
# - Delete feature branch after merge
```

## Common Troubleshooting

### Build Errors

**Error: "The type or namespace name 'X' could not be found"**

```powershell
# Solution 1: Restore packages
dotnet restore

# Solution 2: Clean and rebuild
dotnet clean
dotnet build
```

**Error: "warning MSB3277: Found conflicts between different versions of 'X'"**

```powershell
# Solution: Check package references in .csproj files for version mismatches
# Ensure all projects use same version of shared packages
```

### Test Failures

**Error: "Testcontainers.Containers.ContainerLaunchException"**

```powershell
# Solution 1: Ensure Docker is running
docker ps

# Solution 2: Check Docker resources (memory, CPU)
# Docker Desktop → Settings → Resources

# Solution 3: Pull image manually
docker pull mcr.microsoft.com/mssql/server:2022-latest
```

**Error: "PSRemotingTransportException: Connecting to remote server failed"**

```powershell
# Solution 1: Check WinRM service is running
Get-Service WinRM

# Solution 2: Test WinRM connectivity
Test-WSMan -ComputerName localhost

# Solution 3: Enable WinRM
Enable-PSRemoting -Force
```

### Runtime Issues

**Error: "SqlException: Cannot open database 'CertInventory' requested by the login"**

```powershell
# Solution 1: Verify database exists
sqlcmd -S localhost -Q "SELECT name FROM sys.databases WHERE name = 'CertInventory'"

# Solution 2: Deploy schema
sqlcmd -S localhost -i src/Infrastructure/Persistence/Schema/001-initial-schema.sql

# Solution 3: Check connection string in appsettings.json or user secrets
dotnet user-secrets list --project src/Agent/Agent.csproj
```

**Error: "Azure.Identity.AuthenticationFailedException: DefaultAzureCredential failed to retrieve a token"**

```powershell
# Solution 1: For local dev, use User Secrets instead of Key Vault
dotnet user-secrets set "ServiceAccount:Password" "DevPassword123!" --project src/Agent/Agent.csproj

# Solution 2: Login to Azure CLI
az login

# Solution 3: Check Azure RBAC permissions for Key Vault
az keyvault show --name your-keyvault-name
```

## Code Quality Checks

### Pre-Commit Checklist

Before committing code, run:

```powershell
# 1. Format code
dotnet format

# 2. Build with zero warnings
dotnet build --nologo

# 3. Run all tests
dotnet test --nologo

# 4. Check for uncommitted changes
git status

# 5. Review diff
git diff
```

**Automated pre-commit hook** (optional):

```powershell
# Run setup script
./scripts/setup-githooks.ps1

# This will configure Git to run pre-commit checks automatically
```

### Static Analysis

```powershell
# Run Roslyn analyzers (configured in Directory.Build.props)
dotnet build /p:EnforceCodeStyleInBuild=true

# Run security scan (if DevSkim extension installed)
# Check VS Code Problems panel

# Run dependency vulnerability scan
dotnet list package --vulnerable
```

## Performance Profiling

```powershell
# Run with performance counters
dotnet run --project src/Agent/Agent.csproj --configuration Release

# Collect diagnostics
dotnet trace collect --process-id <PID> --providers Microsoft-Diagnostics-DiagnosticSource

# Memory profiling
dotnet-dump collect --process-id <PID>
dotnet-dump analyze <dump-file>
```

## Logging and Diagnostics

### Local Development Logging

**Serilog sinks configured in `appsettings.Development.json`:**

```json
{
    "Serilog": {
        "MinimumLevel": "Debug",
        "WriteTo": [
            {
                "Name": "Console",
                "Args": {
                    "outputTemplate": "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}"
                }
            },
            {
                "Name": "File",
                "Args": {
                    "path": "logs/inventory-.log",
                    "rollingInterval": "Day",
                    "retainedFileCountLimit": 7
                }
            }
        ]
    }
}
```

**View logs:**

```powershell
# Real-time console logs (when running dotnet run)
# Logs appear in VS Code DEBUG CONSOLE

# File logs
Get-Content logs/inventory-20251121.log -Wait

# SQL logs (if configured)
SELECT TOP 100 * FROM InventoryLogs ORDER BY Timestamp DESC;
```

## Deployment

### Windows Service Deployment

```powershell
# 1. Publish application
dotnet publish src/Agent/Agent.csproj `
    --configuration Release `
    --output "C:\Services\CertInventory" `
    --runtime win-x64 `
    --self-contained true

# 2. Install Windows Service
sc.exe create "CambridgeCertInventory" `
    binPath="C:\Services\CertInventory\Agent.exe" `
    start=auto `
    DisplayName="Cambridge Certificate Inventory Service"

# 3. Configure service account
sc.exe config "CambridgeCertInventory" obj="DOMAIN\svc-certinventory" password="..."

# 4. Start service
sc.exe start "CambridgeCertInventory"

# 5. Verify service status
Get-Service -Name "CambridgeCertInventory"

# 6. View service logs
Get-EventLog -LogName Application -Source "CambridgeCertInventory" -Newest 50
```

## Development Tips

### VS Code Extensions (Recommended)

```
- C# (ms-dotnettools.csharp)
- C# Dev Kit (ms-dotnettools.csdevkit)
- PowerShell (ms-vscode.powershell)
- SQL Server (ms-mssql.mssql)
- Docker (ms-azuretools.vscode-docker)
- GitLens (eamodio.gitlens)
- GitHub Copilot (github.copilot)
```

### Keyboard Shortcuts

```
Ctrl+Shift+B → Build
Ctrl+Shift+T → Run tests
F5 → Start debugging
Ctrl+F5 → Run without debugging
Ctrl+` → Toggle terminal
Ctrl+Shift+P → Command palette
Ctrl+. → Quick fix / refactor
F12 → Go to definition
Shift+F12 → Find all references
```

### Code Snippets

**Create domain entity:**

```csharp
public class EntityName
{
    private EntityName() { } // Force factory method

    public static Result<EntityName> Create(/* parameters */)
    {
        // Validation logic

        return Result.Ok(new EntityName
        {
            // Property initialization
        });
    }
}
```

**Create use case:**

```csharp
public class SomeActionUseCase
{
    private readonly IPortInterface _port;
    private readonly ILogger<SomeActionUseCase> _logger;

    public SomeActionUseCase(IPortInterface port, ILogger<SomeActionUseCase> logger)
    {
        _port = port;
        _logger = logger;
    }

    public async Task<Result<TOutput>> ExecuteAsync(
        TInput input,
        CancellationToken cancellationToken)
    {
        try
        {
            // Orchestration logic
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error message");
            return Result.Fail<TOutput>(ex.Message);
        }
    }
}
```

## Anti-Patterns to Avoid

❌ **Committing without testing**: Always run `dotnet test` before committing
❌ **Hardcoded secrets**: Use User Secrets or Azure Key Vault
❌ **Skipping code formatting**: Run `dotnet format` before commits
❌ **Large commits**: Prefer small, focused commits with clear messages
❌ **Direct main branch commits**: Always use feature branches

## Quick Reference Links

-   Solution file: `InventoryManagement.sln`
-   Configuration: `src/Agent/appsettings.json`, `appsettings.Development.json`
-   User Secrets: `dotnet user-secrets list --project src/Agent/Agent.csproj`
-   Tasks: `.vscode/tasks.json`
-   Build properties: `Directory.Build.props`
-   Git hooks: `scripts/setup-githooks.ps1`

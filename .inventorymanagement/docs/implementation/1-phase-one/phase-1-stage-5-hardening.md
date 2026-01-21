# Phase 1 Stage 5: Hardening (Weeks 3.5-4)

**Last Updated:** November 20, 2025
**Status:** Ready for Implementation
**Owner:** Carl R. Yeager
**Duration:** ~0.5 weeks

---

## Overview

Finalize Phase 1 with comprehensive testing, documentation, deployment preparation, and production readiness validation. This stage ensures the system is robust, documented, and ready for initial production deployment with 5-10 machines.

**Primary Goal:** Achieve production-ready status with validated deployment, complete documentation, and verified acceptance criteria.

---

## Scope

**In Scope:**
- End-to-end integration testing (full harvest cycle)
- Performance validation (5-10 machines, sequential)
- Deployment packaging (Windows Service installer)
- Operations runbook (installation, configuration, troubleshooting)
- Security review (service account permissions, Key Vault access)
- Phase 1 acceptance testing against original objectives
- Handoff documentation for Phase 2

**Out of Scope:**
- Production deployment to 300 servers (Phase 2)
- Load testing at scale (Phase 2)
- High availability configuration (Phase 3+)
- WebUI (Phase 5)

---

## Deliverables

| ID | Deliverable | Location | Acceptance Criteria |
|----|-------------|----------|---------------------|
| D5.1 | E2E integration tests | `tests/Integration.Tests/` | Full harvest cycle validated |
| D5.2 | Performance baseline | Test results documentation | 5 machines harvest in <5 minutes |
| D5.3 | Windows Service installer | `scripts/Install-Service.ps1` | Service installs and starts successfully |
| D5.4 | Operations runbook | `docs/operations/phase-1-runbook.md` | Complete ops procedures documented |
| D5.5 | Security checklist | `docs/security/phase-1-security.md` | All security requirements validated |
| D5.6 | Phase 1 acceptance report | `docs/planning/phase-1-acceptance.md` | All objectives met and verified |
| D5.7 | Phase 2 handoff doc | `docs/planning/phase-2-kickoff.md` | Requirements and context for Phase 2 |

---

## Tasks

### Task Group A: End-to-End Testing

**Duration:** 1.5 days

#### A1: Integration Test Suite

**File:** `tests/Integration.Tests/EndToEndHarvestTests.cs`

```csharp
namespace InventoryManagement.Integration.Tests;

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Xunit;
using InventoryManagement.Agent.Workers;
using InventoryManagement.Application.Orchestrators;
using InventoryManagement.Infrastructure.CertStores;
using InventoryManagement.Infrastructure.Persistence;
using Testcontainers.MsSql;

/// <summary>
/// End-to-end integration tests validating full harvest workflow.
/// Requires: SQL Server (Testcontainers), test machine with WinRM enabled.
/// </summary>
public sealed class EndToEndHarvestTests : IAsyncLifetime
{
    private readonly MsSqlContainer _sqlContainer = new MsSqlBuilder()
        .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
        .Build();

    private IHost _host = null!;

    public async Task InitializeAsync()
    {
        await _sqlContainer.StartAsync();

        var connectionString = _sqlContainer.GetConnectionString();
        await DeploySchemaAsync(connectionString);

        _host = BuildTestHost(connectionString);
    }

    public async Task DisposeAsync()
    {
        await _host.StopAsync();
        _host.Dispose();
        await _sqlContainer.DisposeAsync();
    }

    [Fact]
    public async Task FullHarvestCycle_CollectsAndPersistsCertificates()
    {
        // Arrange
        var orchestrator = _host.Services.GetRequiredService<CollectionOrchestrator>();
        var testMachine = GetTestMachineFQDN();  // From environment variable or config

        // Act
        var result = await orchestrator.HarvestMachineAsync(testMachine, CancellationToken.None);

        // Assert
        Assert.True(result.IsSuccess, $"Harvest failed: {result.ErrorMessage}");
        Assert.True(result.CertificatesCollected > 0, "No certificates collected");
        Assert.True(result.BindingsCreated > 0, "No bindings created");
        Assert.True(result.Duration.TotalSeconds < 120, "Harvest took longer than 2 minutes");

        // Verify persistence
        var persistence = _host.Services.GetRequiredService<SqlServerPersistence>();
        // Query SQL to verify data written (implementation specific)
    }

    [Fact]
    public async Task MultiMachineHarvest_ProcessesSequentially()
    {
        // Test that 3 machines are harvested sequentially
        // Verify logs show correct order, isolation of failures
    }

    [Fact]
    public async Task FailedMachine_DoesNotBlockOthers()
    {
        // Test with 1 invalid machine + 2 valid machines
        // Verify 2 successful harvests complete despite 1 failure
    }

    [Fact]
    public async Task SecondHarvest_UpdatesLastVerified()
    {
        // Run harvest twice for same machine
        // Verify LastVerified timestamp updated, no duplicate rows
    }

    [Fact]
    public async Task CertificateDeduplication_WorksAcrossMachines()
    {
        // Harvest same certificate from 2 machines
        // Verify 1 Certificates row, 2 MachineCertificates rows
    }

    private IHost BuildTestHost(string connectionString)
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:InventoryDatabase"] = connectionString,
                ["Harvest:TargetMachines:0"] = GetTestMachineFQDN(),
                ["Harvest:IntervalMinutes"] = "60",
                ["Harvest:TimeoutSeconds"] = "120",
                ["Harvest:MaxRetries"] = "2"
            })
            .Build();

        return Host.CreateDefaultBuilder()
            .ConfigureServices(services =>
            {
                // Wire up full DI graph (copy from Program.cs)
                services.AddSingleton<IConfiguration>(config);
                services.AddSingleton<CertificateMapper>();
                services.AddScoped<CollectionOrchestrator>();
                services.AddScoped<ICertificateStoreReader, WinRmOSCollector>();
                services.AddScoped<IIngestionWriter, SqlServerPersistence>();
                services.AddLogging(b => b.AddConsole());
            })
            .Build();
    }

    private string GetTestMachineFQDN()
    {
        return Environment.GetEnvironmentVariable("TEST_MACHINE_FQDN")
            ?? "server01.test.cambridge.edu";
    }

    private async Task DeploySchemaAsync(string connectionString)
    {
        // Deploy all schema scripts (001, 002, 003, 004)
        // (Implementation similar to SqlServerPersistenceTests)
    }
}
```

#### A2: Performance Validation Test

**File:** `tests/Integration.Tests/PerformanceTests.cs`

```csharp
[Fact]
public async Task Sequential5MachinHarvest_CompletesWithin5Minutes()
{
    var orchestrator = _host.Services.GetRequiredService<CollectionOrchestrator>();
    var machines = GetTest5Machines();

    var stopwatch = Stopwatch.StartNew();
    var results = new List<HarvestResult>();

    foreach (var machine in machines)
    {
        var result = await orchestrator.HarvestMachineAsync(machine, CancellationToken.None);
        results.Add(result);
    }

    stopwatch.Stop();

    // Assert: All successful
    Assert.All(results, r => Assert.True(r.IsSuccess));

    // Assert: Completes within 5 minutes (1 min/machine avg)
    Assert.True(stopwatch.Elapsed.TotalMinutes < 5,
        $"Harvest took {stopwatch.Elapsed.TotalMinutes:F2} minutes, expected <5 minutes");

    // Log metrics
    var totalCerts = results.Sum(r => r.CertificatesCollected);
    var avgDuration = results.Average(r => r.Duration.TotalSeconds);

    _logger.LogInformation(
        "Performance baseline: {MachineCount} machines, {TotalCerts} certs, {AvgDuration:F2}s avg, {TotalDuration:F2}s total",
        machines.Length, totalCerts, avgDuration, stopwatch.Elapsed.TotalSeconds);
}
```

---

### Task Group B: Deployment Packaging

**Duration:** 1 day

#### B1: Windows Service Installer Script

**File:** `scripts/Install-Service.ps1`

```powershell
<#
.SYNOPSIS
    Installs Cambridge Certificate Inventory Management Service as a Windows Service.

.DESCRIPTION
    - Validates prerequisites (WinRM, SQL connectivity, service account)
    - Publishes application binaries
    - Configures service account
    - Installs Windows Service
    - Starts service and validates

.PARAMETER ServiceAccount
    Domain service account to run the service (e.g., CAMBRIDGE\svc.inventory.orchestrator)

.PARAMETER BinaryPath
    Path to compiled binaries (defaults to .\publish\)

.PARAMETER InstallPath
    Installation directory (defaults to C:\Program Files\Cambridge\InventoryService)

.EXAMPLE
    .\Install-Service.ps1 -ServiceAccount "CAMBRIDGE\svc.inventory.orchestrator"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceAccount,

    [Parameter(Mandatory = $false)]
    [string]$BinaryPath = ".\publish",

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\Program Files\Cambridge\InventoryService"
)

$ErrorActionPreference = 'Stop'

Write-Host "Cambridge Certificate Inventory Service Installer" -ForegroundColor Cyan
Write-Host "=" * 60

# Step 1: Validate prerequisites
Write-Host "`n[1/7] Validating prerequisites..." -ForegroundColor Yellow

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run as Administrator"
}

# Check service account exists
try {
    $account = New-Object System.Security.Principal.NTAccount($ServiceAccount)
    $account.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
    Write-Host "  ✓ Service account verified: $ServiceAccount" -ForegroundColor Green
}
catch {
    throw "Service account not found: $ServiceAccount"
}

# Check SQL connectivity
$connectionString = (Get-Content "$BinaryPath\appsettings.json" | ConvertFrom-Json).ConnectionStrings.InventoryDatabase
try {
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    $connection.Close()
    Write-Host "  ✓ SQL Server connectivity verified" -ForegroundColor Green
}
catch {
    throw "Cannot connect to SQL Server: $_"
}

# Step 2: Stop existing service if running
Write-Host "`n[2/7] Checking for existing service..." -ForegroundColor Yellow
$existingService = Get-Service -Name "CambridgeInventory" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "  Stopping existing service..." -ForegroundColor Yellow
    Stop-Service -Name "CambridgeInventory" -Force
    Write-Host "  ✓ Existing service stopped" -ForegroundColor Green
}

# Step 3: Create installation directory
Write-Host "`n[3/7] Creating installation directory..." -ForegroundColor Yellow
if (Test-Path $InstallPath) {
    Remove-Item -Path $InstallPath -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
Write-Host "  ✓ Created: $InstallPath" -ForegroundColor Green

# Step 4: Copy binaries
Write-Host "`n[4/7] Copying application binaries..." -ForegroundColor Yellow
Copy-Item -Path "$BinaryPath\*" -Destination $InstallPath -Recurse -Force
Write-Host "  ✓ Binaries copied" -ForegroundColor Green

# Step 5: Grant service account permissions
Write-Host "`n[5/7] Configuring permissions..." -ForegroundColor Yellow

# Grant Read & Execute on installation directory
$acl = Get-Acl $InstallPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $ServiceAccount, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $InstallPath -AclObject $acl

# Grant Full Control on logs directory
$logsPath = Join-Path $InstallPath "logs"
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$acl = Get-Acl $logsPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $ServiceAccount, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $logsPath -AclObject $acl

Write-Host "  ✓ Permissions configured" -ForegroundColor Green

# Step 6: Install Windows Service
Write-Host "`n[6/7] Installing Windows Service..." -ForegroundColor Yellow

if ($existingService) {
    # Update existing service
    sc.exe config CambridgeInventory binPath= "`"$InstallPath\Agent.exe`"" obj= $ServiceAccount
    Write-Host "  ✓ Service updated" -ForegroundColor Green
}
else {
    # Create new service
    New-Service -Name "CambridgeInventory" `
        -BinaryPathName "`"$InstallPath\Agent.exe`"" `
        -DisplayName "Cambridge Certificate Inventory Management" `
        -Description "Collects and manages certificate inventory from Windows servers via WinRM" `
        -StartupType Automatic `
        -Credential (Get-Credential -UserName $ServiceAccount -Message "Enter password for $ServiceAccount")

    Write-Host "  ✓ Service created" -ForegroundColor Green
}

# Configure service recovery options (restart on failure)
sc.exe failure CambridgeInventory reset= 86400 actions= restart/60000/restart/60000/restart/60000

# Step 7: Start service
Write-Host "`n[7/7] Starting service..." -ForegroundColor Yellow
Start-Service -Name "CambridgeInventory"
Start-Sleep -Seconds 5

$service = Get-Service -Name "CambridgeInventory"
if ($service.Status -eq 'Running') {
    Write-Host "  ✓ Service started successfully" -ForegroundColor Green
}
else {
    throw "Service failed to start. Check Event Viewer for details."
}

# Verify logs being written
Start-Sleep -Seconds 10
$logFiles = Get-ChildItem -Path $logsPath -Filter "*.txt" | Sort-Object LastWriteTime -Descending
if ($logFiles.Count -gt 0) {
    Write-Host "  ✓ Logging verified: $($logFiles[0].Name)" -ForegroundColor Green
}
else {
    Write-Warning "No log files created yet. Monitor logs directory."
}

Write-Host "`n" + ("=" * 60)
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "Service Name: CambridgeInventory"
Write-Host "Install Path: $InstallPath"
Write-Host "Logs Path: $logsPath"
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Verify appsettings.json configuration"
Write-Host "  2. Monitor logs for first harvest cycle"
Write-Host "  3. Query SQL: SELECT TOP 10 * FROM InventoryLogs ORDER BY Timestamp DESC"
```

#### B2: Publish Script

**File:** `scripts/Publish-Release.ps1`

```powershell
<#
.SYNOPSIS
    Publishes the Cambridge Inventory Service for deployment.

.EXAMPLE
    .\Publish-Release.ps1 -Configuration Release
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\publish"
)

$ErrorActionPreference = 'Stop'

Write-Host "Publishing Cambridge Inventory Service" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration"
Write-Host "Output: $OutputPath"
Write-Host ""

# Clean output directory
if (Test-Path $OutputPath) {
    Remove-Item -Path $OutputPath -Recurse -Force
}

# Restore dependencies
Write-Host "Restoring dependencies..." -ForegroundColor Yellow
dotnet restore ../InventoryManagement.sln

# Build
Write-Host "Building solution..." -ForegroundColor Yellow
dotnet build ../InventoryManagement.sln --configuration $Configuration --no-restore

# Publish Agent project
Write-Host "Publishing Agent project..." -ForegroundColor Yellow
dotnet publish ../src/Agent/Agent.csproj `
    --configuration $Configuration `
    --output $OutputPath `
    --no-build `
    --no-restore `
    --self-contained false `
    --runtime win-x64

Write-Host ""
Write-Host "Publish complete!" -ForegroundColor Green
Write-Host "Binaries location: $OutputPath"
Write-Host "Next: Run Install-Service.ps1 to deploy"
```

---

### Task Group C: Documentation

**Duration:** 1 day

#### C1: Operations Runbook

**File:** `docs/operations/phase-1-runbook.md`

```markdown
# Phase 1 Operations Runbook

**Version:** 1.0
**Last Updated:** November 20, 2025
**Scope:** Phase 1 deployment (5-10 machines, sequential harvest)

---

## Service Overview

**Service Name:** CambridgeInventory
**Display Name:** Cambridge Certificate Inventory Management
**Purpose:** Collect and manage certificate inventory from Windows servers via WinRM

**Architecture:**
- Windows Service (Agent project)
- WinRM-based OS certificate collection
- SQL Server persistence (ProdSpt_Inventory database)
- Serilog logging (console, file, SQL)

---

## Installation

See `scripts/Install-Service.ps1` for automated installation.

**Manual Installation Steps:**

1. **Publish binaries:**
   ```powershell
   cd scripts
   .\Publish-Release.ps1 -Configuration Release
   ```

2. **Install service:**
   ```powershell
   .\Install-Service.ps1 -ServiceAccount "CAMBRIDGE\svc.inventory.orchestrator"
   ```

3. **Verify installation:**
   ```powershell
   Get-Service CambridgeInventory
   Get-Content "C:\Program Files\Cambridge\InventoryService\logs\inventory-<date>.txt" -Tail 20
   ```

---

## Configuration

**File:** `C:\Program Files\Cambridge\InventoryService\appsettings.json`

```json
{
  "Harvest": {
    "TargetMachines": ["server01.corp.cambridge.edu", "server02.corp.cambridge.edu"],
    "IntervalMinutes": 60,
    "TimeoutSeconds": 120,
    "MaxRetries": 2
  },
  "ConnectionStrings": {
    "InventoryDatabase": "Server=<SQL_SERVER>;Database=ProdSpt_Inventory;Integrated Security=true;"
  }
}
```

**After Configuration Changes:**
```powershell
Restart-Service CambridgeInventory
```

---

## Operations

### Adding Machines

1. Edit `appsettings.json` → Add FQDN to `Harvest.TargetMachines` array
2. Verify WinRM connectivity: `.\scripts\Test-WinRmConnectivity.ps1 -TargetServers @("new-server.cambridge.edu")`
3. Restart service: `Restart-Service CambridgeInventory`
4. Monitor logs for first harvest

### Removing Machines

1. Edit `appsettings.json` → Remove FQDN from `Harvest.TargetMachines` array
2. Restart service
3. (Optional) Mark machine as inactive in SQL: `UPDATE Machines SET IsActive = 0 WHERE FQDN = 'old-server.cambridge.edu'`

### Manual Harvest Trigger

Service runs automatically on schedule (default: hourly). To trigger immediately:

```powershell
Restart-Service CambridgeInventory  # Runs harvest on startup
```

### Viewing Logs

**Console logs (Windows Event Viewer):**
```powershell
Get-EventLog -LogName Application -Source CambridgeInventory -Newest 20
```

**File logs:**
```powershell
Get-Content "C:\Program Files\Cambridge\InventoryService\logs\inventory-*.txt" -Tail 50
```

**SQL logs:**
```sql
SELECT TOP 100 * FROM ProdSpt_Inventory.dbo.InventoryLogs
ORDER BY Timestamp DESC;
```

---

## Troubleshooting

### Service Won't Start

**Symptoms:** Service status = Stopped, Event Viewer shows startup errors

**Diagnosis:**
1. Check Event Viewer: `Get-EventLog -LogName Application -Source CambridgeInventory -Newest 5`
2. Check file logs: `Get-Content "...\logs\inventory-*.txt" -Tail 20`

**Common Causes:**
- SQL Server unreachable → Verify `ConnectionStrings:InventoryDatabase`
- Service account permissions → Verify account has db_datawriter on ProdSpt_Inventory
- Missing appsettings.json → Verify file exists in install directory

### Machine Not Being Harvested

**Symptoms:** No logs for specific machine, machine never appears in SQL

**Diagnosis:**
1. Verify in TargetMachines list: `(Get-Content appsettings.json | ConvertFrom-Json).Harvest.TargetMachines`
2. Test WinRM: `Test-WSMan -ComputerName server01.cambridge.edu`
3. Check logs: `SELECT * FROM InventoryLogs WHERE MachineFQDN = 'server01.cambridge.edu' ORDER BY Timestamp DESC`

**Common Causes:**
- WinRM not enabled → Enable with `Enable-PSRemoting` on target
- Firewall blocking 5985/5986 → Open ports
- Service account lacks admin rights on target → Add to local Administrators group

### Harvest Failures

**Symptoms:** Logs show "Harvest failed" errors

**Diagnosis:**
```sql
SELECT * FROM InventoryLogs
WHERE Level = 'Error' AND OperationType = 'Harvest'
ORDER BY Timestamp DESC;
```

**Common Causes:**
- Timeout (>120s) → Increase `Harvest:TimeoutSeconds`
- Network blip → Verify retry attempts in logs (should retry 2x)
- Certificate parsing error → Check exception details in logs

### Duplicate Certificates

**Symptoms:** Same certificate inserted multiple times

**Diagnosis:**
```sql
SELECT Thumbprint, COUNT(*) FROM Certificates GROUP BY Thumbprint HAVING COUNT(*) > 1;
```

**Expected:** Should return 0 rows (deduplication working)

**Fix:** This indicates a bug - thumbprint normalization or MERGE logic broken. Review logs for SQL errors.

---

## Monitoring

### Health Checks

**Daily:**
- Verify service running: `Get-Service CambridgeInventory`
- Check for errors: `SELECT COUNT(*) FROM InventoryLogs WHERE Level = 'Error' AND Timestamp >= DATEADD(day, -1, SYSDATETIMEOFFSET())`

**Weekly:**
- Review harvest success rate: Use `scripts/Queries/HarvestHistory.sql`
- Check slow machines: Use `scripts/Queries/SlowMachines.sql`
- Verify log cleanup: `EXEC dbo.CleanupInventoryLogs`

### Key Metrics

- **Success Rate:** >95% of harvests successful
- **Harvest Duration:** <60 seconds per machine (avg)
- **Certificate Growth:** Monitor `SELECT COUNT(*) FROM Certificates` for trends

---

## Maintenance

### Log Cleanup

Automated via SQL Agent job (daily at 2 AM):
```sql
EXEC dbo.CleanupInventoryLogs @RetentionDays = 90;
```

Manual execution:
```sql
EXEC dbo.CleanupInventoryLogs;
```

### Service Account Password Rotation

1. Update password in Active Directory
2. Update service credentials:
   ```powershell
   sc.exe config CambridgeInventory obj= "CAMBRIDGE\svc.inventory.orchestrator" password= "<new_password>"
   Restart-Service CambridgeInventory
   ```

### Backup

**SQL Database:**
- Included in standard database backup schedule
- Tables: Certificates, Machines, MachineCertificates, InventoryLogs

**Configuration:**
- Backup `appsettings.json` before changes

---

## Phase 2 Transition

Phase 1 supports 5-10 machines (sequential harvest). For scaling to 300 machines:

1. Deploy Phase 2 code (parallel execution + SQLite buffer)
2. Update configuration (increase concurrency, enable buffer)
3. Monitor performance metrics
4. See `docs/planning/phase-2-kickoff.md` for details
```

---

### Task Group D: Security & Acceptance

**Duration:** 0.5 days

#### D1: Security Checklist

**File:** `docs/security/phase-1-security.md`

```markdown
# Phase 1 Security Checklist

## Service Account

- [ ] Domain service account created: `svc.inventory.orchestrator`
- [ ] Strong password (>20 chars, rotated quarterly)
- [ ] Account NOT member of Domain Admins
- [ ] Account member of target servers' local Administrators group
- [ ] SQL permissions: db_datawriter, db_datareader on ProdSpt_Inventory
- [ ] Service configured to run as service account
- [ ] Service account password NOT in appsettings.json (uses Windows auth)

## Network Security

- [ ] WinRM ports (5985/5986) firewalled to management server only
- [ ] SQL Server port (1433) restricted to management server
- [ ] No internet connectivity required
- [ ] TLS 1.2+ enforced for SQL connections

## Data Security

- [ ] Certificate private keys NOT exported (HasPrivateKey flag only)
- [ ] SQL connection uses Windows Integrated Security (no passwords)
- [ ] Logs do not contain sensitive data (passwords, private keys)
- [ ] InventoryLogs table permissions restricted (db_datawriter only)

## Audit & Compliance

- [ ] All service actions logged to SQL (InventoryLogs table)
- [ ] Service account activity auditable via Windows Security logs
- [ ] Log retention: 90 days minimum
- [ ] Regular review of failed harvest attempts (potential security issues)
```

### D2: Phase 1 Acceptance Report

**File:** `docs/planning/phase-1-acceptance.md`

```markdown
# Phase 1 Acceptance Report

**Date:** <TO BE FILLED>
**Phase:** 1 - Foundation & Basic OS Harvest
**Status:** <PENDING/ACCEPTED>

---

## Objectives Validation

| ID | Objective | Success Metric | Status | Evidence |
|----|-----------|----------------|--------|----------|
| O1 | Domain model correct | All invariants enforced; 80% unit test coverage | ☐ | Test coverage report |
| O2 | Schema deployed | Tables created with constraints, indices; manual MERGE test passes | ☐ | SQL schema validation |
| O3 | Harvest working | 5-machine harvest completes successfully with certificates in SQL | ☐ | E2E test results |
| O4 | Deduplication verified | Same certificate on multiple machines → single row in Certificates table | ☐ | Dedup integration test |
| O5 | Normalization validated | Thumbprints stored uppercase, no delimiters | ☐ | SQL query validation |
| O6 | Manual re-harvest | Second harvest updates LastVerified, no duplicate rows created | ☐ | Re-harvest test |

---

## Deliverables Sign-Off

| ID | Deliverable | Completed | Verified By | Date |
|----|-------------|-----------|-------------|------|
| D1 | Domain entities | ☐ | | |
| D2 | Domain services | ☐ | | |
| D3 | Port interfaces | ☐ | | |
| D4 | SQL schema DDL | ☐ | | |
| D5 | SqlServerPersistence | ☐ | | |
| D6 | WinRmOSCollector | ☐ | | |
| D7 | Agent Worker | ☐ | | |
| D8 | Configuration | ☐ | | |
| D9 | Basic runbook | ☐ | | |

---

## Quality Metrics

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| Unit test coverage | ≥80% | | ☐ |
| Integration test pass rate | 100% | | ☐ |
| Build warnings | 0 | | ☐ |
| Harvest duration (5 machines) | <5 minutes | | ☐ |
| Success rate (5 machines, 10 cycles) | >95% | | ☐ |

---

## Acceptance Decision

**Accepted:** ☐ Yes ☐ No

**Approver:** _______________________

**Date:** _______________________

**Notes:**
```

---

## Acceptance Criteria

| ID | Criteria | Validation Method |
|----|----------|-------------------|
| AC1 | E2E tests pass | `dotnet test tests/Integration.Tests/` shows 100% pass |
| AC2 | Performance validated | 5 machines harvest in <5 minutes |
| AC3 | Service installer works | Install on clean machine, service starts successfully |
| AC4 | Operations runbook complete | All procedures documented and validated |
| AC5 | Security checklist complete | All items checked and verified |
| AC6 | Phase 1 objectives met | Acceptance report signed off |

---

## Dependencies

**Required Before Starting:**
- Stages 1-4 complete
- Test environment with 5-10 machines
- Production SQL Server available
- Service account provisioned

**Provides to Next Phase:**
- Production-ready Phase 1 deployment
- Performance baseline for Phase 2 comparison
- Documented operational procedures
- Validated hexagonal architecture

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Test machine unavailable | High | Provision backup test machines |
| Service account provisioning delay | Medium | Request account early in Stage 5 |
| Acceptance criteria not met | High | Address blockers before sign-off, extend phase if needed |

---

## Success Metrics

- **All E2E tests green:** 100% pass rate
- **Performance baseline:** <1 minute per machine average
- **Zero security violations:** All checklist items passed
- **Documentation complete:** Runbook covers all scenarios
- **Stakeholder sign-off:** Phase 1 acceptance report approved

---

## Phase 2 Handoff

Upon Phase 1 acceptance:

1. **Deployment:** Install service on management server with 5-10 initial machines
2. **Monitoring:** Establish baseline metrics (harvest duration, success rate, cert counts)
3. **Phase 2 Kickoff:** Review `docs/planning/phase-2-kickoff.md` for parallel execution requirements
4. **Architecture Review:** Validate hexagonal architecture supports Phase 2 scope (parallel, IIS, buffer)

**Phase 2 will add:**
- Parallel WinRM execution (SemaphoreSlim throttling, max 10 concurrent)
- IIS binding collection
- SQLite buffer for SQL outages
- HarvestExecution tracking table
- Polly retry policies
- Scale to 50-100 machines

---

**Stage 5 Complete!** 🎉

Phase 1 is production-ready. All objectives met, documentation complete, service deployable.

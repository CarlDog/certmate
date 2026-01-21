# ⚠️ SUPERSEDED DOCUMENT - DO NOT USE

**This document has been superseded by:**

- `docs/architecture/architectural-decisions.md` (authoritative ADRs, especially ADR-002)
- `docs/architecture/implementation-roadmap.md` (current implementation plan)

**Reason for archiving:** This document recommended a simplified 3-project structure, but the final architectural decision (ADR-002) retained the full 7-project hexagonal architecture with incremental population.

**Archived:** November 20, 2025

---

## C# Inventory Management Implementation Plan (Updated for ADRs) - OUTDATED VERSION

**Status:** SUPERSEDED - See above for current documentation
**See:** `architectural-decisions.md` for complete ADR context

---

## ⚠️ MAJOR CHANGES FROM ORIGINAL PLAN

### 1. **Deployment Model:** Central Orchestrator (ADR-001)

- **Original:** Assumed local agents on each server (like v1.0)
- **Updated:** Central Windows Service with WinRM remoting to 300+ servers
- **Rationale:** v1.0 was failed experiment (sporadic, glitchy), need centralized control

### 2. **Project Structure:** Simplified to 3 Projects (ADR-002)

- **Original:** 7 projects (Domain, Application, Infrastructure, Agent, 3 test projects)
- **Updated:** 3 projects (InventoryCollector, InventoryAgent, InventoryCollector.Tests)
- **Rationale:** Over-engineered for single-implementation use case, defer layering until needed

### 3. **Credentials:** Azure Key Vault (ADR-005)

- **Original:** GMSA for all auth
- **Updated:** Service account + Azure Key Vault for secrets (F5 password, etc.)
- **Rationale:** GMSA doesn't work for F5 REST API

### 4. **Schema Fix:** Surrogate Key for MachineCertificates (ADR-007)

- **Original:** Composite PK `(MachineId, Thumbprint, SourceType)`
- **Updated:** Surrogate `Id` + unique constraint on `(MachineId, Thumbprint, SourceType, PathLocation)`
- **Rationale:** Same cert can exist in multiple stores (My, Root, CA) - original PK causes data loss

---

## High-Level Goals (Unchanged)

- Replace v1.0 PowerShell collection with reliable C# orchestrator
- Normalize certificate metadata across all sources (OS, F5, IIS, cert repo)
- Provide comprehensive deployment metadata (BindingContext JSON)
- **Critical constraint:** Central orchestrator with WinRM remoting (no agents on targets)

## Operational Parameters

- **Scale**: ~300 Windows servers, 5 F5 devices, ~1,000 total certificates
- **SLO**: End-to-end harvest completes under 30 minutes
- **Concurrency**: Max 10 concurrent WinRM sessions (ADR-001)
- **Transport**: WinRM for OS/IIS (ports 5985/5986), CIFS for repo PFX share
- **F5**: BIG-IP 17.1.3 (Build 0.0.11); rate limit 5 req/s
- **Deployment**: Single Windows Service on management server
- **Identity**: Service account `svc.inventory.orchestrator` with Azure Key Vault secrets (ADR-005)

## Domain Model (Simplified - No Value Objects Yet)

- **Certificate**: Thumbprint (string), Subject, SANs, Issuer, NotBefore, NotAfter, HasPrivateKey, KeyUsageFlags, EnhancedKeyUsages, KeyAlgorithm, SignatureAlgorithm, SerialNumber, KeySize, IsSelfSigned
- **Machine**: MachineId (int), FQDN, NetBiosName, Environment, Roles (JSON), FirstSeen, LastSeen, WinRMStatus, IsActive
- **MachineCertificate**: Id (surrogate key), MachineId, Thumbprint, SourceType, PathLocation, BindingContext (JSON), DateDiscovered, LastVerified, DeletedAt (ADR-004)

**Normalization:** Thumbprint uppercase, no colons (simple function, no value object)

**Deduplication:** One `Certificate` row per thumbprint, many `MachineCertificate` associations

---

## Simplified Project Structure (ADR-002)

### Phase 1-2: Certificate Collection

```text
InventoryManagement/
├── src/
│   ├── InventoryCollector/           # Class Library (all collection logic)
│   │   ├── Certificates/
│   │   │   ├── Certificate.cs        # POCO model
│   │   │   ├── WinRmCertificateCollector.cs
│   │   │   ├── IisCertificateCollector.cs
│   │   │   └── CertificateNormalizer.cs (static helpers)
│   │   ├── Machines/
│   │   │   ├── Machine.cs
│   │   │   └── MachineCertificate.cs
│   │   ├── Persistence/
│   │   │   ├── SqlServerPersistence.cs  # MERGE upserts
│   │   │   └── SqliteBuffer.cs          # ADR-003: Conditional buffering
│   │   ├── F5/
│   │   │   └── F5RestClient.cs
│   │   ├── Repository/
│   │   │   └── PfxRepositoryCollector.cs
│   │   ├── Policies/
│   │   │   └── PollyPolicies.cs         # Retry, rate limiting
│   │   └── Configuration/
│   │       ├── WinRmConfiguration.cs
│   │       ├── F5Configuration.cs
│   │       └── SqlConfiguration.cs
│   ├── InventoryAgent/               # Windows Service (orchestration)
│   │   ├── Worker.cs                 # BackgroundService
│   │   ├── Program.cs                # DI composition, Key Vault setup
│   │   └── appsettings.json
│   └── InventoryCollector.Tests/    # xUnit tests
│       ├── WinRmCollectorTests.cs
│       ├── SqlPersistenceTests.cs
│       └── SqliteBufferTests.cs
├── tests/
│   └── (integrated above)
├── docs/
│   └── architecture/
│       ├── architectural-decisions.md   # All ADRs
│       ├── architectural-review.md      # Critical analysis
│       ├── hexagonal-overview.md        # Updated for simplified approach
│       └── v1-schema-analysis.md        # Schema design
└── v1.0/                             # Legacy (read-only)
```

### Phase 3: WebUI (Future)

```text
├── src/
│   └── InventoryWeb/                 # ASP.NET Core Razor Pages or Blazor
│       ├── Pages/
│       │   ├── Reports/
│       │   └── Exports/
│       └── Shared/
│           └── DataAccess.cs         # Reuse SqlServerPersistence
```

---

## Remote Harvest Strategy (ADR-001: Central WinRM Orchestrator)

### Windows OS Certificate Stores

```csharp
// Central service runs on management server
using var connectionInfo = new WSManConnectionInfo(
    new Uri($"http://{targetMachine}:5985/wsman"),
    "http://schemas.microsoft.com/wsman/2004/06/authentication/Kerberos",
    _serviceAccountCredential);

using var runspace = RunspaceFactory.CreateRunspace(connectionInfo);
runspace.Open();

var script = @"
    Get-ChildItem -Path Cert:\LocalMachine\My, Cert:\LocalMachine\Root |
    Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey
";

var results = PowerShell.Create(runspace).AddScript(script).Invoke();
```

### IIS Bindings (via WinRM)

```csharp
var script = @"
    Import-Module WebAdministration;
    Get-WebBinding |
    Select-Object Protocol, BindingInformation, CertificateHash, SiteName
";
```

### F5 BIG-IP 17.1.3 REST API

```csharp
// Token auth + rate limiting (5 req/s)
var rateLimiter = Policy.RateLimitAsync(5, TimeSpan.FromSeconds(1));
await rateLimiter.ExecuteAsync(() =>
    _httpClient.GetAsync($"{_baseUrl}/mgmt/tm/ltm/profile/client-ssl"));
```

### Repository (PFX Share via CIFS)

```csharp
// Access \\fileserver\certs\ using service account
var pfxFiles = Directory.GetFiles(@"\\fileserver\certs", "*.pfx", SearchOption.AllDirectories);
foreach (var pfxFile in pfxFiles)
{
    var cert = new X509Certificate2(pfxFile);  // No password import, metadata only
    // Extract Subject, Thumbprint, etc.
}
```

---

## Concurrency and Rate Limiting (ADR-001)

### WinRM Concurrency Control

```csharp
var semaphore = new SemaphoreSlim(10);  // Max 10 concurrent sessions
var tasks = targetMachines.Select(async machine =>
{
    await semaphore.WaitAsync(cancellationToken);
    try
    {
        return await CollectFromMachineAsync(machine, cancellationToken);
    }
    finally
    {
        semaphore.Release();
    }
});

var results = await Task.WhenAll(tasks);
```

### F5 Rate Limiting (Polly)

```csharp
public static class PollyPolicies
{
    public static IAsyncPolicy<HttpResponseMessage> F5RateLimiter =>
        Policy.RateLimitAsync<HttpResponseMessage>(
            numberOfExecutions: 5,
            perTimeSpan: TimeSpan.FromSeconds(1),
            maxBurst: 5);

    public static IAsyncPolicy<HttpResponseMessage> WinRmRetry =>
        Policy<HttpResponseMessage>
            .Handle<HttpRequestException>()
            .WaitAndRetryAsync(3, retryAttempt =>
                TimeSpan.FromSeconds(Math.Pow(2, retryAttempt)));
}
```

---

## Persistence Model (ADR-004, ADR-006, ADR-007)

### Machine Registration (ADR-006: Upsert)

## Alerting Policy

- Scope: Production environment only; 30-day expiry window.
- Delivery: Weekly digest message; suppress repeat alerts per certificate after first notification.
- Escalation: Increase severity as expiry approaches (e.g., 30, 14, 7, 3 days) within the weekly digest.
- Publisher: Teams webhook publisher; group by environment and application where available.

## Scheduling

- Single service schedule initially (e.g., nightly). Architecture supports per-adapter cadence later (e.g., F5 hourly, OS nightly).
- Manual trigger endpoint optional in future API.

## Failure Handling and Outcomes

- Partial success retained; do not rollback on adapter errors.
- Classify outcomes as Success, Partial, Failed with reason codes; always log errors with source attribution.
- No deactivation/inactive marking at this time; failures are logged for remediation.

## Persistence Model (Canonical Certificates)

- Tables:
  - `Certificates` (canonical by Thumbprint): current metadata only (no history per scope).
  - `MachineCertificates` (association): Machine, Thumbprint, SourceType, PathLocation, BindingContext, SourceAdapter, DateDiscovered.
- Upsert: Parameterized MERGE semantics; partial writes allowed per record.
- No historical retention for prior NotAfter values (per scope).

## Configuration & Deployment

- Config layers: appsettings.json + environment overrides; feature flags for adapter enablement and schedules.
- Identity: GMSA for all remote access; no secrets vault required initially.
- Packaging: Windows Service with install/uninstall script; pipeline-driven deployments.

## Proposed Solution Layout

InventoryManagement/
  src/
    Domain/
      Certificates/
      Machines/
      Services/
      Interfaces/
      Implementations/
    Application/
      Harvest/
      Commands/
      UseCases/
    Infrastructure/
      Persistence/
      Logging/
      CertStores/
      F5/
      Secrets/
      Messaging/
      Retry/
    Agent/
      Worker/
      Configuration/
    Api/ (optional)
      Controllers/
      DTOs/
      Shared/
      Abstractions/
      Errors/
  tests/
    Domain.Tests/
    Infrastructure.Tests/
    Application.Tests/
  build/
  scripts/
  docs/
    architecture/
      hexagonal-overview.md
      ports-and-adapters.md
  tools/
    PowerShellMigration/
    Legacy/

## Layer Responsibilities

- **Domain**: Pure logic, no IO.
- **Application**: Coordinates domain services and ports.
- **Infrastructure**: Adapters for external systems.
- **Agent (Host)**: DI registration, scheduling, lifetime management.
- **API**: External driving adapters (optional).

## Data Flow (Machine Cert Harvest)

Timer → Application HarvestCommand → Domain → Ports:

- ICertificateStoreReader (LocalMachine)
- IUserProfileStoreReader (optional)
- (Future) Remote F5 queries separated

Normalizer → Deduplicator → IngestionWriter → LoggingPort/Metrics

## Staged Rollout Plan

- **Phase 0**: Bootstrap solution, DI, logging, config, Thumbprint model
- **Phase 1**: LocalMachine harvest, pilot, compare vs PowerShell
- **Phase 2**: User store + chain details
- **Phase 3**: Repo + F5 integration
- **Phase 4**: Persistence & alerting
- **Phase 5**: Decommission remote PS cert collection
- **Phase 6**: Expand to IIS, scheduled tasks

## Migration Notes

- Keep collectionLogs inserts initially; pivot to InventoryLogs when stable
- Add ingestion status table (ExecutionId, Machine, Counts, Errors JSON)
- Tag cert rows with SourceAgentVersion

## Security & Secrets

- Use GMSA for authentication; no secrets storage required initially.
- Principle of least privilege for SQL writes
- Sign agent binaries for distribution

## Testing Strategy

- Domain: Pure unit tests (NUnit/xUnit)
- Infrastructure: DI + mocks, ephemeral SQL
- Cert store reader: Temp certs for test run
- F5RestClient: Mock HTTP handler
- Lab: Synthetic test lab with expired, weak, and duplicate certificates for end-to-end validation.

## Observability

- Serilog sinks: Console and rolling file (Seq optional later)
- Metrics (minimal initial): harvest_duration_ms, certificates_collected_total, certificates_expiring_30d_total
- Health: Last successful harvest timestamp metric; API health endpoint optional later

## Example Interfaces

```csharp
public interface ICertificateStoreReader {
    Task<IReadOnlyCollection<Certificate>> GetMachineCertificatesAsync(CancellationToken ct);
}
public interface IIngestionWriter {
    Task<IngestionOutcome> PersistAsync(IEnumerable<Certificate> certs, Machine machine, CancellationToken ct);
}
public interface ICertificateNormalizer {
    Certificate Normalize(Certificate raw);
}
```

## Agent Worker Sketch

```csharp
public class Worker : BackgroundService {
    private readonly ICertificateCollectionCommand _harvest;
    private readonly ILogger<Worker> _logger;
    private readonly TimeSpan _interval;
    public Worker(ICertificateCollectionCommand harvest, ILogger<Worker> logger, IConfiguration config) {
        _harvest = harvest; _logger = logger;
        _interval = TimeSpan.FromMinutes(config.GetValue<int>("Harvest:IntervalMinutes", 60));
    }
    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        while (!stoppingToken.IsCancellationRequested) {
            var started = DateTimeOffset.UtcNow;
            try {
                await _harvest.ExecuteAsync(stoppingToken);
                _logger.LogInformation("Harvest completed in {Elapsed} ms", (DateTimeOffset.UtcNow - started).TotalMilliseconds);
            } catch (Exception ex) {
                _logger.LogError(ex, "Harvest failed");
            }
            await Task.Delay(_interval, stoppingToken);
        }
    }
}
```

## Scaffolding Commands

```sh
dotnet new sln -n InventoryManagement
dotnet new classlib -n Domain -o src/Domain
dotnet new classlib -n Application -o src/Application
dotnet new classlib -n Infrastructure -o src/Infrastructure
dotnet new worker -n Agent -o src/Agent
dotnet new xunit -n Domain.Tests -o tests/Domain.Tests
dotnet sln add src/Domain src/Application src/Infrastructure src/Agent tests/Domain.Tests
dotnet add src/Application reference src/Domain
dotnet add src/Infrastructure reference src/Domain
dotnet add src/Agent reference src/Application src/Infrastructure
dotnet add tests/Domain.Tests reference src/Domain
dotnet add src/Infrastructure package Serilog.AspNetCore Polly Microsoft.Data.SqlClient
```

## PULL-ONLY Constraint

> All collectors must operate in PULL mode. No remote agents or push-based collection allowed. Data is gathered centrally by orchestrators; remote hosts are never modified.

---
For questions or issues, contact Carl R. Yeager. Update this plan as new architectural decisions are made.

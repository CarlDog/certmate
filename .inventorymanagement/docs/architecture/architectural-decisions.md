# Architectural Decisions Record (ADR)

**Date:** November 19, 2025
**Status:** Approved
**Scope:** v2.0 C# Inventory Management System

---

## Core Architectural Decisions

### ✅ **ADR-001: Central WinRM Orchestrator Model**

**Decision:** Build a central Windows Service that orchestrates remote collection via WinRM to 300+ Windows servers.

**Context:**

- v1.0 used local scripts on each server (failed experiment - sporadic, glitchy)
- Need centralized control, unified scheduling, and reliable execution
- Single point of management preferred over 300+ distributed agents

**Implementation:**

- Central Windows Service runs on dedicated management server
- WinRM remoting to enumerate certificate stores on remote machines
- PowerShell remoting sessions for IIS configuration collection
- CIFS access for certificate repository (PFX share)
- F5 REST API calls from central service

**Concurrency:**

- Max 10 concurrent WinRM sessions (configurable)
- Semaphore-based throttling via Polly policies
- Retry on transient failures (network blips, target server reboots)

**Rationale:**

- Centralized scheduling and monitoring
- No agent deployment/maintenance on 300+ servers
- Easier troubleshooting (logs in one place)
- WinRM is already enabled for server management

**Risks:**

- Network dependencies (WinRM requires 5985/5986 open)
- Firewall rules required for central → target communication
- Service account must have admin rights on all target servers
- Single point of failure (mitigated by Windows Service clustering if needed)

---

### ✅ **ADR-002: Full Hexagonal Architecture with Incremental Population**

**Decision:** Retain complete 7-project hexagonal structure and populate layers incrementally as features are built.

**Project Structure:**

1. **`Domain`** (Class Library) - Pure business logic, zero dependencies
   - Entities: Certificate, Machine, MachineCertificate
   - Value objects: Thumbprint (when complexity justifies)
  - Domain services: CertificateNormalizer, ExpiryEvaluator
  - Port interfaces: ICertificateStoreReader, IIngestionWriter, IF5RestClient, ITeamsNotifier

2. **`Application`** (Class Library) - Use case orchestration
  - Use cases: LocalCertificates, SendWeeklyDigest
  - Command handlers: ICertificateCollectionCommand
  - Orchestrators: CollectionOrchestrator
  - Depends on: Domain only

3. **`Infrastructure`** (Class Library) - External adapters
  - Persistence: SqlServerPersistence, SqliteBuffer
  - Certificate collectors: WinRmCertificateCollector, F5RestClient, RepositoryPfxReader
  - Messaging: TeamsWebhookPublisher
  - Policies: PollyPolicies (retry, rate limiting)
  - Depends on: Domain only

4. **`Agent`** (Windows Service) - Hosting and composition
  - Worker: BackgroundService with scheduled harvests
  - DI composition root
  - Configuration binding (appsettings.json + Azure Key Vault)
  - Serilog logging
  - Depends on: Application, Infrastructure

5. **`Domain.Tests`** (xUnit) - Pure unit tests
6. **`Application.Tests`** (xUnit) - Use case tests with mocked ports
7. **`Infrastructure.Tests`** (xUnit) - Adapter integration tests

**Phase 3 Addition:**
8. **`InventoryWeb`** (ASP.NET Core) - WebUI for reports and exports

**Rationale:**

- **This is a platform, not a script** - Multi-year infrastructure management system with incremental features (scheduled tasks, IIS inventory, compliance reporting)
- **Phase 3 WebUI requires shared layers** - Domain models and Infrastructure adapters used by both Agent and Web
- **Scaffold already exists** - 47 files committed, builds cleanly, provides clear organization
- **Future-proofing matches stated vision** - "build onto, layer by layer, for managing and tracking our infrastructure"
- **Deleting would be counterproductive** - Would recreate same structure in 6-12 months for Phase 3+

**Guard Rails to Prevent Over-Engineering:**

1. **No NotImplementedException in main branch** - Implement or delete placeholder methods
2. **Interfaces only when needed** - Delete ICertificateStoreReader until second implementation exists
3. **Real tests or no tests** - Empty test projects must be populated or removed
4. **Document scaffold intent** - README explains incremental population strategy
5. **Validate layers add value** - If a layer becomes pure pass-through, collapse it

**Incremental Population Plan:**

- **Phase 1 (4 weeks, Weeks 1-4):** Domain models + Infrastructure (SQL, WinRM) + Agent orchestration (sequential OS harvest)
- **Phase 2 (4 weeks, Weeks 5-8):** Parallel execution + IIS + Infrastructure (SQLite buffer) + HarvestExecution tracking
- **Phase 3 (4 weeks, Weeks 9-12):** Machine Discovery (AD sync) + Soft delete lifecycle + Recovery logic
- **Phase 4 (5 weeks, Weeks 13-17):** Infrastructure (F5 REST, Repository PFX) + Circuit breaker patterns
- **Phase 5 (5 weeks, Weeks 18-22):** InventoryWeb + Export + Alert subscriptions + Shared Domain/Infrastructure

**This is NOT YAGNI violation because:**

- We WILL use all layers (Phase 5 WebUI confirmed)
- We WILL add features (scheduled tasks, IIS, services inventory planned)
- We WILL need abstraction (WebUI + Agent sharing persistence)
- The cost of scaffold is already paid (committed code)

**When to Revisit:**

- After Phase 3 delivery - assess if layering added value or friction
- If team consensus shifts to monolith preference
- If maintenance burden exceeds benefit

---

### ✅ **ADR-003: Conditional SQLite Buffering**

**Decision:** Implement **lightweight SQLite buffer** with strict scope limits to handle network failures without excessive complexity.

**Scope:**

- Buffer ONLY if SQL Server connection fails (transient or prolonged)
- Serialize collected certificates to local SQLite database
- Retry upload on next harvest run
- Purge uploaded records after 7 days

**Implementation:**

```csharp
// Simplified buffering logic
try
{
    await _sqlPersistence.UpsertCertificatesAsync(certificates);
}
catch (SqlException ex) when (IsNetworkError(ex))
{
    await _sqliteBuffer.BufferAsync(certificates);
    _logger.LogWarning("SQL Server unreachable, buffered {Count} certs", certificates.Count);
}

// Next run: upload buffered data first
var buffered = await _sqliteBuffer.GetPendingAsync();
foreach (var batch in buffered)
{
    await _sqlPersistence.UpsertCertificatesAsync(batch);
    await _sqliteBuffer.MarkUploadedAsync(batch.Id);
}
```

**Limits to Avoid Over-Engineering:**

- NO complex state machine (Pending/Uploading/Failed) - just Pending/Uploaded
- NO retry backoff in buffer layer (retry happens on next scheduled harvest)
- NO conflict resolution (if cert changes between buffer and upload, last write wins)
- NO distributed transactions (buffer is best-effort)

**SQLite Schema:**

```sql
-- SQLite database: %ProgramData%\CambridgeInventory\buffer.db
-- Purpose: Temporary buffer for SQL Server outages

CREATE TABLE PendingUploads (
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    HarvestTimestamp TEXT NOT NULL,              -- ISO 8601: 2025-11-20T14:30:00Z
    MachineName TEXT NOT NULL,                   -- Target machine harvested
    CertificatesJson TEXT NOT NULL,              -- JSON array: Certificate[]
    MachineCertificatesJson TEXT NOT NULL,       -- JSON array: MachineCertificate[]
    CreatedAt TEXT NOT NULL,                     -- ISO 8601: When buffered
    UploadedAt TEXT,                             -- NULL = pending, NOT NULL = uploaded
    RetryCount INTEGER NOT NULL DEFAULT 0,       -- Number of upload attempts
    LastError TEXT                               -- Last SQL error message
);

CREATE INDEX IX_PendingUploads_UploadedAt ON PendingUploads (UploadedAt);
CREATE INDEX IX_PendingUploads_CreatedAt ON PendingUploads (CreatedAt);

-- Example JSON structure:
-- CertificatesJson: [{"Thumbprint":"ABC123...","Subject":"CN=server.com",...}]
-- MachineCertificatesJson: [{"MachineId":42,"Thumbprint":"ABC123...","SourceType":"LocalMachine","PathLocation":"My"}]
```

**Auto-Purge Policy:**

- Delete uploaded records older than 7 days (keep for audit/diagnostics)
- Delete failed uploads older than 30 days (prevent unbounded growth)
- Execute on service startup and after each successful upload batch

**Operational Limits:**

- Max 1000 pending batches (fail-fast if exceeded to detect systemic issues)
- Max batch size: 10MB JSON (typical harvest = ~500 certs × 2KB = 1MB)
- Log warning if buffer exceeds 100 batches (indicates prolonged SQL outage)

**Rationale:**

- Network failures DO happen (SQL Server maintenance, network blips)
- Losing 30-60 minutes of cert data is acceptable, losing days is not
- SQLite adds ~100 lines of code vs potential data loss
- SQLite is embedded (no separate service/installation)

**Alternative Considered (Rejected):**

- **Message Queue (MSMQ/Azure Service Bus):** Overkill for single-producer/single-consumer
- **No buffering:** Risk of data loss during extended outages acceptable per user tolerance

---

### ✅ **ADR-004: Soft Delete with 90-Day Grace Period**

**Decision:** Use **soft delete** for certificate removal with 90-day grace period before cleanup.

**Schema Addition (Phase 1):**

```sql
-- DeletedAt column present in Phase 1 schema
ALTER TABLE MachineCertificates ADD DeletedAt DATETIME2 NULL;
```

**Lifecycle Logic (Phase 3):**

```sql
-- Mark as deleted if not seen in harvest (Phase 3 implementation)
UPDATE MachineCertificates
SET DeletedAt = SYSDATETIMEOFFSET()
WHERE LastVerified < @HarvestStartTime
  AND DeletedAt IS NULL;

-- Cleanup after 90 days (Phase 3 scheduled job)
DELETE FROM MachineCertificates
WHERE DeletedAt < DATEADD(day, -90, SYSDATETIMEOFFSET());
```

**Behavior:**

1. **Phase 1:** Column exists in schema; always NULL (lifecycle logic not implemented)
2. **Phase 3:** During harvest, collect current certificate inventoryate inventory
3. After harvest, mark any `MachineCertificates` NOT seen as deleted (set `DeletedAt`)
4. Scheduled cleanup job removes rows where `DeletedAt > 90 days ago`
5. Queries by default filter `WHERE DeletedAt IS NULL` (only active certs)

**Rationale:**

- Certs can be temporarily removed/re-added (server rebuilds, testing)
- 90 days matches machine inactivity grace period (consistent policy)
- Soft delete allows "undelete" if cert reappears (just clear `DeletedAt`)
- Historical queries can include deleted certs if needed

**Implementation Note:**
MERGE upsert logic must UPDATE `DeletedAt = NULL` if cert reappears (resurrection).

---

### ✅ **ADR-005: Service Account with Azure Key Vault**

**Decision:** Use traditional Windows service account with **Azure Key Vault** for credential storage (F5, SQL).

**Context:**

- GMSA works for Windows-integrated auth (SQL, WinRM) but NOT for F5 REST API
- F5 requires username/password or token-based auth
- Hardcoded passwords in config/source are unacceptable

**Implementation:**

```csharp
// appsettings.json
{
  "AzureKeyVault": {
    "VaultUri": "https://cambridgeinventory.vault.azure.net/"
  },
  "F5": {
    "Username": "svc.f5.readonly",
    "PasswordSecretName": "F5-ServiceAccount-Password"  // Key Vault secret name
  }
}

// Startup
builder.Configuration.AddAzureKeyVault(
    new Uri(vaultUri),
    new DefaultAzureCredential());  // Uses managed identity or service principal

// F5Client
var password = _configuration["F5:PasswordSecretName"];  // Auto-fetched from Key Vault
```

**Service Account Setup:**

1. Create `svc.inventory.orchestrator` domain account
2. Grant permissions:
   - SQL: `db_datawriter`, `db_datareader` on `ProdSpt_Inventory`
   - WinRM: Local admin on target servers (or delegated permissions)
   - Azure: Reader on Key Vault, Secret Get permission
3. Configure Windows Service to run as `svc.inventory.orchestrator`

**Secrets in Key Vault:**

- `F5-ServiceAccount-Password`: F5 API password
- `SQL-ConnectionString`: Full connection string (if not using Windows auth)
- Future: Repository PFX passwords (if encrypted)

**Rationale:**

- Azure Key Vault is industry standard for secret management
- Managed identity eliminates credential management for Key Vault access
- Secrets rotated in Key Vault without code/config changes
- Audit logging for secret access

**Fallback (Non-Azure Environments):**

- Windows Credential Manager (DPAPI-encrypted local storage)
- Service logs warning if Key Vault unavailable

---

### ✅ **ADR-006: Machine Registration via Upsert**

**Decision:** Machine registration happens via **MERGE upsert** during harvest, no pre-population required.

**Flow:**

```csharp
// 1. Harvest certs from target machine
var certificates = await CollectCertificates(targetMachine);

// 2. Upsert machine record (idempotent)
var machineId = await EnsureMachineRegistered(
    fqdn: targetMachine.FQDN,
    netbiosName: targetMachine.NetBiosName,
    environment: DetermineEnvironment(targetMachine.FQDN)
);

// 3. Upsert certificates
await UpsertCertificates(certificates, machineId);
```

**SQL MERGE for Machines:**

```sql
MERGE INTO Machines AS target
USING (VALUES (@Hostname, @FQDN, @Environment)) AS source (Hostname, FQDN, Environment)
ON target.Hostname = source.Hostname
WHEN MATCHED THEN
    UPDATE SET
        LastSeen = SYSDATETIMEOFFSET(),
        WinRMStatus = 'Reachable',
        FQDN = source.FQDN  -- Update if changed
WHEN NOT MATCHED THEN
    INSERT (Hostname, FQDN, Environment, FirstSeen, LastSeen, WinRMStatus, IsActive)
    VALUES (source.Hostname, source.FQDN, source.Environment,
            SYSDATETIMEOFFSET(), SYSDATETIMEOFFSET(), 'Reachable', 1)
OUTPUT INSERTED.MachineId;
```

**Error Handling:**

- Hostname uniqueness enforced by database constraint
- DNS resolution failures logged, machine skipped for current run
- Duplicate hostnames handled by MERGE (upsert behavior)

**Rationale:**

- No manual machine inventory maintenance
- Self-healing (machines auto-register on first successful harvest)
- Failed machines don't block others (isolated transactions per machine)

---

### ✅ **ADR-007: Fixed MachineCertificates Primary Key**

**Decision:** Use **surrogate key** with unique constraint on business key to handle multiple store locations.

**Schema:**

```sql
CREATE TABLE MachineCertificates (
    Id INT IDENTITY(1,1) PRIMARY KEY,  -- Surrogate key
    MachineId INT NOT NULL,
    Thumbprint NVARCHAR(64) NOT NULL,  -- Supports SHA-256 (64) and SHA-1 (40)
    SourceType NVARCHAR(20) NOT NULL,      -- OS, IIS, F5, Repo
    PathLocation NVARCHAR(500) NOT NULL,   -- LocalMachine\My, /Common/cert.crt
    BindingContext NVARCHAR(MAX),          -- JSON metadata
    DateDiscovered DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    LastVerified DATETIMEOFFSET NOT NULL,
    DeletedAt DATETIME2 NULL,              -- ADR-004: Soft delete (Phase 1 schema; lifecycle logic Phase 3)
    CONSTRAINT UQ_MachineCertBinding UNIQUE (MachineId, Thumbprint, SourceType, PathLocation),
    CONSTRAINT FK_MachineCertificates_Machine FOREIGN KEY (MachineId) REFERENCES Machines(MachineId),
    CONSTRAINT FK_MachineCertificates_Certificate FOREIGN KEY (Thumbprint) REFERENCES Certificates(Thumbprint),
    CONSTRAINT CK_BindingContext_IsJson CHECK (ISJSON(BindingContext) = 1 OR BindingContext IS NULL)
);
```

**Example Data (Same Cert, Multiple Locations):**

```text
Id | MachineId | Thumbprint | SourceType | PathLocation
---|-----------|------------|------------|------------------
1  | 42        | ABC123...  | OS         | LocalMachine\My
2  | 42        | ABC123...  | OS         | LocalMachine\Root
3  | 42        | ABC123...  | IIS        | LocalMachine\WebHosting
```

**Rationale:**

- Handles real-world scenario (cert in multiple stores/bindings)
- Surrogate key simplifies JOINs and future references
- Unique constraint prevents duplicate (Machine, Cert, Source, Path) entries
- PathLocation included in business key for precision

---

### ✅ **ADR-008: Phased Delivery Timeline (REVISED)**

**Decision:** Deliver in **5 phases** with 4-5 week increments (total 22 weeks).

**Revision History:** Originally 3 phases (20 weeks). Restructured to 5 phases based on historical pattern of Phase 1 over-ambition. New structure reduces Phase 1 scope by 67% (8 epics → 3 epics) to validate WinRM approach early with minimal risk.

**Phase 1 (Weeks 1-4): Foundation & Basic OS Harvest**

  - Domain model (Certificate, Machine, MachineCertificate entities)
  - SQL schema + MERGE persistence (includes HarvestExecutions, InventoryLogs tables for future use)
  - WinRM OS collector (sequential, no parallelization)
  - Basic logging (console + file)
  - Manual machine registration (config file)
  - Unit + integration tests
  - Soft delete columns present (DeletedAt in MachineCertificates; lifecycle logic deferred to Phase 3)
  - **Deferred:** AD discovery, IIS, soft delete logic, buffer, parallel execution, SQL sink wiring

**Phase 2 (Weeks 5-8): Scale & Resilience**

  - Parallel WinRM execution (SemaphoreSlim, max 10 concurrent)
  - Polly retry policies (exponential backoff)
  - IIS binding collection (builds on WinRM patterns)
  - HarvestExecution tracking table
  - Serilog SQL sink + correlation IDs
  - SQLite buffer + replay job
  - **Deferred:** AD discovery, soft delete

**Phase 3 (Weeks 9-12): Machine Discovery & Lifecycle**

  - MachineDiscoveryWorker (ADR-009 AD sync)
  - LDAP query + application-side filtering
  - Soft delete for MachineCertificates (detect missing, set DeletedAt)
  - Recovery logic (clear DeletedAt if reappears)
  - Machine-level soft delete (inactive servers)
  - Configuration (include/exclude lists, grace periods)
  - **Deferred:** F5, Repository

**Phase 4 (Weeks 13-17): F5 & Repository Integration**

  - F5RestClient with token auth + rate limiting + circuit breaker
  - SSL profile → certificate mapping
  - RepositoryPfxReader (CIFS enumeration, read-only metadata)
  - Extended SourceType enum (OS, IIS, F5, Repository)
  - BindingContext JSON for F5 metadata
  - **Deferred:** WebUI

**Phase 5 (Weeks 18-22): WebUI & Reporting**

  - `InventoryWeb` ASP.NET Core (Razor Pages or Blazor)
  - Inventory search (filter by FQDN, thumbprint, expiry, source)
  - Expiry dashboard (counts + trend charts)
  - CSV export (streaming for large datasets)
  - Alert subscriptions (read-only UI)
  - Windows auth integration

**Timeline Flexibility:**

## Project Structure (Hexagonal Architecture)

```text
InventoryManagement/
├── src/
│   ├── Domain/                        # Pure business logic (no dependencies)
│   │   ├── Certificates/
│   │   │   ├── Certificate.cs
│   │   │   ├── Thumbprint.cs         # Value object (when justified)
│   │   │   └── CertificateCollectionResult.cs
│   │   ├── Machines/
│   │   │   ├── Machine.cs
│   │   │   └── MachineCertificate.cs
│   │   ├── Services/
│   │   │   ├── CertificateNormalizer.cs
│   │   │   ├── CertificateDeduplicator.cs
│   │   │   └── ExpiryEvaluator.cs
│   │   └── Interfaces/               # Ports (outbound)
│   │       ├── ICertificateStoreReader.cs
│   │       ├── IIngestionWriter.cs
│   │       ├── IF5RestClient.cs
│   │       ├── ITeamsNotifier.cs
│   │       └── IClock.cs
│   ├── Application/                   # Use case orchestration
│   │   ├── Commands/
│   │   │   └── ICertificateCollectionCommand.cs
│   │   ├── Collection/
│   │   │   └── CollectionOrchestrator.cs
│   │   └── UseCases/
│   │       ├── LocalCertificates.cs
│   │       ├── HarvestRemoteCertificatesUseCase.cs
│   │       └── SendWeeklyDigest.cs
│   ├── Infrastructure/                # External adapters (implements Domain ports)
│   │   ├── Persistence/
│   │   │   ├── SqlServerPersistence.cs
│   │   │   ├── SqliteBuffer.cs
│   │   │   └── SqlLogger.cs
│   │   ├── CertStores/
│   │   │   ├── WindowsCertStoreReader.cs
│   │   │   ├── RemoteWinRmCertCollector.cs
│   │   │   └── RepositoryPfxReader.cs
│   │   ├── F5/
│   │   │   ├── F5RestClient.cs
│   │   │   └── F5CertificateCollector.cs
│   │   ├── Messaging/
│   │   │   └── TeamsWebhookPublisher.cs
│   │   ├── Retry/
│   │   │   └── PolicyFactory.cs
│   │   └── Secrets/
│   │       └── SecretsProvider.cs
│   ├── Agent/                         # Windows Service host (composition root)
│   │   ├── Worker.cs
│   │   ├── Configuration/
│   │   │   ├── SqlConfiguration.cs
│   │   │   ├── F5Configuration.cs
│   │   │   ├── WinRmConfiguration.cs
│   │   │   ├── InventoryConfiguration.cs
│   │   │   └── ServiceRegistration.cs
│   │   ├── Scheduling/
│   │   │   └── WorkerPlaceholder.cs
│   │   ├── appsettings.json
│   │   └── Program.cs
│   └── InventoryWeb/                  # Phase 5 - WebUI
│       ├── Pages/
│       ├── Reports/
│       └── Exports/
├── tests/
│   ├── Domain.Tests/                  # Pure unit tests (no I/O)
│   ├── Application.Tests/             # Use case tests (mocked ports)
│   └── Infrastructure.Tests/          # Adapter integration tests
├── docs/
│   └── architecture/
│       ├── architectural-decisions.md (this file)
│       ├── archive/architectural-review-SUPERSEDED.md    # archived historical critique
│       ├── hexagonal-overview.md
│       ├── archive/ports-and-adapters-SUPERSEDED.md      # archived historical port/adapter draft
│       └── v1-schema-analysis.md
├── build/
├── scripts/
└── v1.0/                              # Legacy (read-only)
```

---

## Implementation Notes

### WinRM Remoting Pattern

```csharp
using var runspace = RunspaceFactory.CreateRunspace(connectionInfo);
runspace.Open();
using var pipeline = runspace.CreatePipeline();
pipeline.Commands.AddScript(@"
    Get-ChildItem -Path Cert:\LocalMachine\My |
    Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter
");
var results = pipeline.Invoke();
```

### Concurrency Control

```csharp
// Limit concurrent WinRM sessions
var semaphore = new SemaphoreSlim(10);
await Parallel.ForEachAsync(machines, async (machine, ct) =>
{
    await semaphore.WaitAsync(ct);
    try
    {
        await CollectFromMachine(machine, ct);
    }
    finally
    {
        semaphore.Release();
    }
});
```

### F5 Rate Limiting (Polly)

```csharp
var rateLimiter = Policy.RateLimitAsync(5, TimeSpan.FromSeconds(1));
await rateLimiter.ExecuteAsync(() => _httpClient.GetAsync(endpoint));
```

---

## Open Questions / Future Decisions

1. **Scheduled Task Inventory:** Expand to collect scheduled tasks (out of scope for Phase 1-2)?
2. **IIS Application Pool Inventory:** Include app pool config in BindingContext?
3. **Certificate Chain Validation:** Validate cert chains or just store leaf metadata?
4. **Historical Trending:** Track cert NotAfter changes over time (requires separate history table)?
5. **Multi-Tenant Support:** Separate inventories by business unit/environment?

---

## Success Metrics

**Phase 1:**

- ✅ 100% of target servers successfully harvested (300 machines)
- ✅ <30 min end-to-end harvest duration
- ✅ Zero data loss during SQL outages (SQLite buffer validated)
- ✅ <5% error rate on WinRM connections

**Phase 2:**

- ✅ F5 inventory complete (5 devices, ~1000 certs)
- ✅ Repository PFX inventory complete
- ✅ v1.0 decommissioned (scheduled tasks disabled, tables archived)

**Phase 3:**

- ✅ 90% of cert queries self-serviced via WebUI (vs SQL)
- ✅ Weekly digest delivery <1 min
- ✅ Export to Excel functional for all reports

---

## ✅ **ADR-009: Machine Discovery & Lifecycle Management**

**Decision:** Use **Active Directory sync via dedicated background worker** to populate and maintain the Machines table as the source of truth. Machines table drives all harvesting operations independently of AD sync timing.

**Context:**

The system needs to know which Windows servers exist in the infrastructure (~300 servers currently, growing). The Machines table must stay synchronized with Active Directory without blocking certificate harvesting operations. As additional collectors are added (IIS, scheduled tasks, Windows services), all will share the same Machines table.

**Architecture: Multiple Independent BackgroundService Workers**

```csharp
// src/Agent/Program.cs - Extensible worker pattern
services.AddHostedService<MachineDiscoveryWorker>();      // AD sync job
services.AddHostedService<CertificateCollectionWorker>();    // Cert collector
services.AddHostedService<IisInventoryWorker>();          // Future: IIS collector
services.AddHostedService<ScheduledTaskInventoryWorker>(); // Future: Task collector
```

**Design Principles:**

1. **Machines table is source of truth** - All workers query Machines for target servers
2. **Independent workers** - Each runs on separate schedule, no blocking dependencies
3. **Extensibility first** - Additional collectors follow same pattern as layers are added
4. **Clean separation** - Single responsibility per worker, shared DI container

---

**Worker 1: MachineDiscoveryWorker (AD Sync)**

**Responsibility:** Keep Machines table synchronized with Active Directory

**Schedule:** Daily (configurable), independent of all other workers

**AD Query Strategy:**

- **Generic LDAP query**: `(objectClass=computer)` - no OU filtering in query
- **Application-side filtering**: AD structure is poorly organized, filters applied in C# code
- **Filters**:
  - OS contains "Server" (exclude workstations)
  - Not in decommissioned OUs
  - Not test/dev naming patterns (configurable)
  - Include/exclude override lists from config

**Configuration:**

```json
{
  "MachineDiscovery": {
    "SyncIntervalHours": 24,
    "LdapFilter": "(objectClass=computer)",
    "ExcludePatterns": ["TEST-*", "DEV-*", "TEMP-*"],
    "ExcludeOUs": ["OU=Decommissioned", "OU=Workstations"],
    "IncludeList": ["dmz-web-01"],     // Manual additions
    "ExcludeList": ["old-server-legacy"] // Manual exclusions
  }
}
```

---

**Soft Delete with Resurrection (90-Day Purge)**

**When server removed from AD:**

```sql
UPDATE Machines
SET IsActive = 0,
    DeletedAt = GETUTCDATE(),
    DeletedBy = 'AD-Sync',
    DeletedReason = 'Removed from Active Directory'
WHERE Hostname NOT IN (SELECT Hostname FROM @CurrentAdServers)
  AND DeletedAt IS NULL;
```

**If server reappears in AD within 90 days:**

```sql
MERGE Machines AS target
USING @AdServers AS source
ON target.Hostname = source.Hostname
WHEN MATCHED AND target.DeletedAt IS NOT NULL THEN
    UPDATE SET
        IsActive = 1,
        DeletedAt = NULL,
        DeletedBy = NULL,
        DeletedReason = NULL,
        LastSeenAt = GETUTCDATE()
WHEN NOT MATCHED THEN
    INSERT (Hostname, FQDN, ...) VALUES (...);
```

**After 90 days (separate maintenance worker):**

```sql
DELETE FROM Machines
WHERE DeletedAt < DATEADD(DAY, -90, GETUTCDATE());
```

**Rationale:** Servers may be temporarily decommissioned, moved between OUs, or offline. 90-day grace period allows resurrection without losing historical certificate data.

---

**WinRM Connection Failure Strategy: Backoff + Alert Threshold**

**Policy:** Connection failures do NOT trigger lifecycle purges. Only AD removal triggers soft delete.

**Backoff Strategy:**

```csharp
public async Task HandleConnectionFailureAsync(Machine machine, WinRmException ex, CancellationToken ct)
{
    var failureCount = await _persistence.IncrementConnectionFailureCountAsync(
        machine.MachineId, ex.Message, ct);

    // Exponential backoff: 1st fail = retry next harvest, 5th+ fail = daily retry
    if (failureCount >= 5)
    {
        await _persistence.SetNextRetryAfterAsync(
            machine.MachineId,
            DateTime.UtcNow.AddHours(24), // Skip next few harvests
            ct);
    }
}
```

**Alert Threshold:**

```csharp
// Alert if unreachable >24 hours
if (machine.LastSuccessfulScan < DateTime.UtcNow.AddHours(-24))
{
    await _alertService.SendAlertAsync(
        $"Server {machine.Hostname} unreachable for 24+ hours", ct);
}
```

**Schema Additions:**

```sql
ALTER TABLE Machines ADD ConnectivityFailureCount INT NOT NULL DEFAULT 0;
ALTER TABLE Machines ADD NextRetryAfter DATETIME2 NULL;
```

**Query for reachable machines:**

```sql
SELECT * FROM Machines
WHERE IsActive = 1
  AND (NextRetryAfter IS NULL OR NextRetryAfter < GETUTCDATE())
```

---

**v1.0 Code Reuse Policy**

**Principle:** Assume all v1.0 PowerShell code is sub-optimal. Research thoroughly before adoption.

**Process:**

1. Identify v1.0 pattern (e.g., `machineList.ps1` AD query logic)
2. Analyze what worked (LDAP query, filter concepts)
3. Analyze what failed (synchronous execution, error handling, performance)
4. Redesign in C# from first principles (async/await, Polly policies, structured logging)
5. Do NOT copy-paste - rewrite with lessons learned

**Example:** If `machineList.ps1` used specific LDAP filters, research the query structure, then implement modern equivalent with `System.DirectoryServices` async patterns.

---

**Rationale:**

- **Machines table as truth**: Harvesting decoupled from AD queries (AD can be slow/unavailable)
- **Multiple workers**: Clean separation, independent schedules, extensibility for future layers
- **Application-side filtering**: Compensates for poorly organized AD structure
- **Soft delete + resurrection**: Operational flexibility, preserves history for auditing
- **Backoff + alerts**: Balances retry efficiency with operational awareness, doesn't confuse connectivity with lifecycle
- **v1.0 research policy**: Learn from history without repeating mistakes

**Risks & Mitigations:**

- **Risk**: AD sync fails, Machines table becomes stale
  - **Mitigation**: Log failures, alert on 3+ consecutive sync failures
- **Risk**: Application filters too restrictive (miss valid servers)
  - **Mitigation**: Include/exclude lists, audit logs of filtered servers
- **Risk**: WinRM backoff too aggressive (miss recovering servers)
  - **Mitigation**: Backoff resets on successful connection, max 24-hour cap

**Decision Date:** November 20, 2025

---

## Revision History

- **2025-11-19:** Initial ADR document created with ADRs 001-008
- **2025-11-20:** Added ADR-009 (Machine Discovery & Lifecycle Management) - AD sync via dedicated background worker, Machines table as source of truth, soft delete with resurrection, WinRM backoff strategy
- **Next Review:** After implementing MachineDiscoveryWorker and first AD sync test

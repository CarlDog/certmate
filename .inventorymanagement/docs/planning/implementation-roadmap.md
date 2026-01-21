# Implementation Roadmap - Next Steps

**Date:** November 20, 2025
**Status:** Architecture finalized, ready for Phase 1 implementation
**All ADRs Approved:** See `architectural-decisions.md`
**Timeline:** 5 phases, 22 weeks total (Weeks 1-4, 5-8, 9-12, 13-17, 18-22)

---

## ✅ Completed: Architectural Review & Decision Making

### Critical Issues Resolved

1. ✅ **Deployment Model Confirmed:** Central WinRM orchestrator (ADR-001)
2. ✅ **Hexagonal Architecture Committed:** Full 7-project structure with incremental population (ADR-002 REVISED)
3. ✅ **Schema Bug Fixed:** MachineCertificates now uses surrogate key + PathLocation (ADR-007)
4. ✅ **Machine Registration Defined:** MERGE upsert returns MachineId (ADR-006)
5. ✅ **Credentials Secured:** Service account + Azure Key Vault (ADR-005)
6. ✅ **Deletion Handling:** Soft delete with 90-day grace period (ADR-004)
7. ✅ **Buffering Decision:** Conditional SQLite for SQL outages (ADR-003)
8. ✅ **Timeline Established:** 5 phases, 4-5 weeks each (ADR-008 REVISED)

### **ADR-002 REVISED: Full Hexagonal Architecture Confirmed**

**Decision:** Retain complete 7-project hexagonal structure, populate incrementally as features are built.

**Rationale:**

- This is a **platform, not a script** - Multi-year infrastructure management vision
- Phase 3 WebUI will share Domain models and Infrastructure adapters
- Additional features planned (scheduled tasks, IIS inventory, services, compliance)
- Scaffold already complete (47 files committed, builds cleanly)
- **NOT YAGNI**: Phase 3 confirmed, feature expansion planned, multiple consumption models

**Guard Rails:**

- No `NotImplementedException` in main branch
- Interfaces only when second implementation exists
- Real tests or no test projects
- Document scaffold intent in README

### Documentation Updated

- ✅ `architectural-decisions.md` - Complete ADR record (ADR-001 through ADR-009)
- ✅ `PRE-IMPLEMENTATION-REVIEW.md` - Consolidated readiness summary (architectural-review archived)
- ✅ `hexagonal-overview.md` - Updated for simplified approach
- ✅ `v1-schema-analysis.md` - Schema corrected with ADR references
- ✅ `csharp-hexagonal-plan.md` - Updated with WinRM orchestrator model

---

## Phase Structure Evolution

**Original Plan:** 3 phases, 20 weeks total (Weeks 1-8, 9-14, 15-20)

**Revised Plan:** 5 phases, 22 weeks total (Weeks 1-4, 5-8, 9-12, 13-17, 18-22)

**Rationale:** Historical pattern of Phase 1 over-ambition. Original Phase 1 combined 3 distinct systems (AD discovery + OS/IIS harvest + soft delete lifecycle) into 8 weeks with 8 epics. Applying lessons learned from previous projects, we restructured to deliver incremental value with reduced risk:

- **Phase 1 (Weeks 1-4):** Foundation & Basic OS Harvest - Validates WinRM approach (highest risk) early with minimal scope
- **Phase 2 (Weeks 5-8):** Scale & Resilience - Production capacity + IIS collection building on proven WinRM patterns
- **Phase 3 (Weeks 9-12):** Machine Discovery & Lifecycle - AD integration + soft delete isolated for dedicated focus
- **Phase 4 (Weeks 13-17):** F5 & Repository Integration - Additional certificate sources extending proven patterns
- **Phase 5 (Weeks 18-22):** WebUI & Reporting - User-facing interface consuming stable backend

**Trade-offs:** +2 weeks total duration for 67% Phase 1 scope reduction (8 epics → 3 epics), working software at Week 4 instead of Week 8, and 5 demonstration milestones instead of 3.

**See detailed phase plans:** `phase-1-plan.md` through `phase-5-plan.md`

---

## 🎯 Phase 1: Foundation & Basic OS Harvest (Weeks 1-4)

**Objective:** Working OS certificate harvest for 5-10 machines with manual registration

**Detailed Plan:** See `phase-1-plan.md`

### Week 1: Project Setup & Schema

**Goal:** Validate existing scaffold, deploy schema, configure Key Vault

#### Tasks

1. **Audit Existing Projects (Already Complete)**
   - ✅ Domain project exists with placeholder models
   - ✅ Application project exists with placeholder use cases
   - ✅ Infrastructure project exists with placeholder adapters
   - ✅ Agent project exists with Worker and DI setup
   - ✅ Test projects exist (Domain.Tests, Application.Tests, Infrastructure.Tests)
   - **Action:** Verify all projects build cleanly (should already pass)

2. **Generate DDL Scripts**
   - Create `docs/architecture/schema-ddl.sql` with:
     - Certificates table (canonical)
     - Machines table (dynamic discovery)
     - MachineCertificates table (surrogate key, PathLocation in unique constraint)
     - HarvestExecutions table (run tracking)
     - InventoryLogs table (enhanced logging)
   - Include all indexes, foreign keys, constraints
   - JSON validation constraint for BindingContext

3. **Deploy Schema to Test SQL Server**
   - Run DDL on test instance
   - Validate constraints, indexes
   - Test MERGE statements manually

4. **Setup Azure Key Vault (Test Environment)**
   - Create Key Vault: `cambridgeinventory-test`
   - Add secrets: `F5-ServiceAccount-Password`, `SQL-ConnectionString`
   - Configure Managed Identity for test service account
   - Test secret retrieval with Azure CLI

5. **Configure appsettings.json**
   - Add Azure Key Vault configuration
   - Add WinRM settings (max concurrency, target servers)
   - Add F5 settings (devices, username, rate limit)
   - Add SQL connection string
   - Add Serilog configuration (console + file + SQL)

**Deliverable:** Empty projects with correct references, SQL schema deployed, Key Vault configured

---

### Week 2-3: Domain Models & SQL Persistence

**Goal:** Implement models and MERGE upserts

#### Tasks

1. **Implement Domain Models** (`src/Domain/`)
   - `Certificates/Certificate.cs` - Replace placeholder with full properties
     - Thumbprint, Subject, Issuer, SANs, NotBefore, NotAfter, HasPrivateKey
     - KeyAlgorithm, SignatureAlgorithm, SerialNumber, KeySize, IsSelfSigned
     - Remove `NotImplementedException`, add real properties
   - `Machines/Machine.cs` - Replace placeholder with full properties
     - MachineId, FQDN, NetBiosName, Environment, Roles (JSON)
     - FirstSeen, LastSeen, WinRMStatus, IsActive
   - `Machines/MachineCertificate.cs` - Replace placeholder with full properties
     - Id (surrogate), MachineId, Thumbprint, SourceType, PathLocation
     - BindingContext (JSON), DateDiscovered, LastVerified
   - `Services/CertificateNormalizer.cs` - Implement static normalization methods
     - NormalizeThumbprint (uppercase, remove colons)
     - ValidateCertificate (basic validation rules)

2. **Implement SqlServerPersistence** (`src/Infrastructure/Persistence/`)

   ```csharp
   public class SqlServerPersistence
   {
       public async Task<int> UpsertMachineAsync(Machine machine, CancellationToken ct);
       public async Task UpsertCertificatesAsync(Certificate[] certs, int machineId, CancellationToken ct);
       public async Task<IngestionOutcome> PersistHarvestAsync(Certificate[] certs, Machine machine, CancellationToken ct);
   }
   ```

   - Machine MERGE (returns MachineId)
   - Certificates MERGE (by Thumbprint)
   - MachineCertificates MERGE (surrogate key, unique constraint on business key)
   - **No soft delete logic yet** (deferred to Phase 3)

3. **Write Unit Tests** (`tests/Domain.Tests/`, `tests/Infrastructure.Tests/`)
   - `CertificateTests.cs` - Test model validation, property mapping
   - `CertificateNormalizerTests.cs` - Test thumbprint normalization
   - `SqlPersistenceTests.cs` - Test MERGE logic with Testcontainers or LocalDB
   - **Remove placeholder UnitTest1.cs files**

**Deliverable:** Persistence layer working with real tests passing

---

### Week 4: WinRM Collection & End-to-End Validation

**Goal:** Implement remote PowerShell collection for OS certs and validate end-to-end harvest

#### Tasks

1. **Configure WinRM on Test Servers**
   - Enable WinRM on 2-3 test servers
   - Configure firewall rules (5985/5986)
   - Test with `Enter-PSSession` manually

2. **Implement WinRmCertificateCollector** (`src/Infrastructure/CertStores/`)
   - Replace `RemoteWinRmCertCollector.cs` placeholder with real implementation

   ```csharp
   public class WinRmCertificateCollector
   {
       public async Task<Certificate[]> CollectAsync(string targetMachine, CancellationToken ct);
   }
   ```

   - Use `System.Management.Automation` NuGet package
   - Create remote runspace with WSManConnectionInfo
   - Execute PowerShell script: `Get-ChildItem Cert:\LocalMachine\My, Root, CA, AuthRoot`
   - Parse results into Certificate POCOs
   - Handle WinRM failures gracefully (log and continue)

3. **Implement Worker** (`src/Agent/Worker.cs`)
   - Replace placeholder Worker with simple sequential harvest orchestration

   ```csharp
   public class Worker : BackgroundService
   {
       protected override async Task ExecuteAsync(CancellationToken stoppingToken)
       {
           while (!stoppingToken.IsCancellationRequested)
           {
               await RunHarvestAsync(stoppingToken);
               await Task.Delay(TimeSpan.FromMinutes(_config.IntervalMinutes), stoppingToken);
           }
       }

       private async Task RunHarvestAsync(CancellationToken ct)
       {
           var machines = _config.TargetServers;

           // SEQUENTIAL - no parallelization yet (Phase 2)
           foreach (var machine in machines)
           {
               try
               {
                   var certs = await _winRmCollector.CollectAsync(machine, ct);
                   await _persistence.PersistHarvestAsync(certs, machine, ct);
               }
               catch (Exception ex)
               {
                   _logger.LogError(ex, "Harvest failed for {Machine}", machine);
               }
           }
       }
   }
   ```

4. **Setup DI in Program.cs** (`src/Agent/Program.cs`)
   - Wire up Domain interfaces → Infrastructure implementations
   - Register Agent services (WinRmCollector, SqlServerPersistence)
   - Bind configuration from appsettings.json
   - Configure Serilog (console + file only - no SQL sink yet)

5. **Write Integration Tests** (`tests/Infrastructure.Tests/`)
   - `WinRmCollectorTests.cs` - Test against real test server (or mock)
   - Validate certificate parsing
   - Validate error handling
   - **Remove placeholder files from Infrastructure.Tests**

6. **End-to-End Validation**
   - Run service locally
   - Harvest from 5 test servers (sequential)
   - Verify certificates in SQL tables
   - Verify deduplication (same cert across machines = 1 row)
   - Re-run harvest, verify LastVerified updates
   - Performance check: 5 machines should complete in < 2 minutes

**Deliverable:** Working end-to-end OS certificate harvest for 5-10 machines

---

## 🚀 Phase 2: Scale & Resilience (Weeks 5-8)

**Objective:** Production-scale harvest (300 servers) with parallel execution, IIS collection, and resilience features

**Detailed Plan:** See `phase-2-plan.md`

### Summary

- **Weeks 5-6:** Parallel execution with Polly retry policies, IIS binding collection, HarvestExecution tracking
- **Weeks 7-8:** Enhanced logging (Serilog SQL sink), SQLite buffer + replay job, production deployment to 300 servers

**Key Deliverables:**
- Parallel WinRM execution (SemaphoreSlim, max 10 concurrent)
- IIS binding collection with BindingContext JSON
- HarvestExecution tracking table (run metadata)
- SQLite buffer for SQL outage resilience
- Production-scale validated (50-machine harvest < 5 minutes, projected 300-machine < 30 minutes)

**Deferred to Phase 3:** AD discovery, soft delete lifecycle

---

## 🔍 Phase 3: Machine Discovery & Lifecycle (Weeks 9-12)

**Objective:** Automated machine discovery from Active Directory + soft delete operational

**Detailed Plan:** See `phase-3-plan.md`

### Summary

- **Weeks 9-10:** MachineDiscoveryWorker (ADR-009), LDAP queries, application-side filtering, resurrection logic
- **Weeks 11-12:** Soft delete for MachineCertificates (detect missing, set DeletedAt), recovery logic, configuration management

**Key Deliverables:**
- AD sync populating Machines table (≥95% of servers)
- Soft delete marking missing certificates
- Recovery logic clearing DeletedAt when certificates reappear
- Machine-level soft delete for inactive servers

**Deferred to Phase 4:** F5, Repository sources

---

## 🌐 Phase 4: F5 & Repository Integration (Weeks 13-17)

**Objective:** Add F5 LTM SSL profiles and certificate repository sources

**Detailed Plan:** See `phase-4-plan.md`

### Summary

- **Weeks 13-15:** F5 REST client (auth, rate limiting, circuit breaker), SSL profile → certificate mapping
- **Weeks 16-17:** Repository PFX scanner (CIFS enumeration), extended SourceType enum, performance validation

**Key Deliverables:**
- F5 REST client with resilience patterns (Polly circuit breaker)
- F5 SSL profiles mapped to certificates with BindingContext JSON
- Repository PFX scanner (read-only metadata extraction)
- All 4 certificate sources operational (OS, IIS, F5, Repository)

**Deferred to Phase 5:** WebUI, reporting, alert subscriptions

---

## 📊 Phase 5: WebUI & Reporting (Weeks 18-22)

**Objective:** User-facing ASP.NET Core WebUI for self-service inventory access and reporting

**Detailed Plan:** See `phase-5-plan.md`

### Summary

- **Weeks 18-20:** ASP.NET Core WebUI (Razor Pages or Blazor), inventory search, expiry dashboard, CSV export
- **Weeks 21-22:** Alert subscriptions (read-only UI), Windows auth integration, security hardening, stakeholder sign-off

**Key Deliverables:**
- WebUI with inventory search (filter by FQDN, thumbprint, expiry, source)
- Expiry dashboard with counts and trend charts
- CSV export (streaming for large datasets)
- Alert subscription management (read-only display)
- Windows authentication, security review passed

---

## 📊 Success Metrics

### Phase 1 Exit (Week 4)

- ✅ Harvest 5 machines successfully (OS certificates only)
- ✅ Certificates deduplicated in SQL (Thumbprint unique constraint)
- ✅ Manual re-harvest updates LastVerified timestamp
- ✅ Basic logging operational (console + file)

### Phase 2 Exit (Week 8)

- ✅ 50-machine harvest completes in < 5 minutes
- ✅ Projected 300-machine harvest < 30 minutes (linear extrapolation)
- ✅ IIS binding collection operational with BindingContext JSON
- ✅ SQLite buffer replay validated under injected SQL failure

### Phase 3 Exit (Week 12)

- ✅ AD sync populates ≥95% of production servers
- ✅ Soft delete marks missing certificates (DeletedAt timestamp)
- ✅ Recovery logic clears DeletedAt when certificates reappear
- ✅ Machine resurrection logic validated (inactive → active transition)

### Phase 4 Exit (Week 17)

- ✅ All 5 F5 devices harvested successfully
- ✅ Repository PFX scanner operational (CIFS share)
- ✅ All 4 sources working (OS, IIS, F5, Repository)
- ✅ Circuit breaker validated under F5 REST API failure
- ✅ Performance within +20% of Phase 3 baseline

### Phase 5 Exit (Week 22)

- ✅ WebUI deployed and accessible (Windows auth)
- ✅ Inventory query performance < 2 seconds
- ✅ CSV export of 10,000 rows < 10 seconds
- ✅ Expiry dashboard showing current data
- ✅ Security review passed (no critical/high vulnerabilities)
- ✅ Stakeholder sign-off (5+ pilot users endorsing solution)

---

## 🔧 Development Environment Setup

### Prerequisites

- Visual Studio 2022 or VS Code with C# extensions
- .NET 9.0 SDK
- SQL Server 2019+ (test instance)
- Azure subscription (for Key Vault)
- PowerShell 5.1+ (for WinRM testing)

### Initial Setup (Already Complete)

The hexagonal scaffold is **already in place**:

```bash
# Verify solution structure
dotnet sln list
# Should show: Domain, Application, Infrastructure, Agent, Domain.Tests, Application.Tests, Infrastructure.Tests

# Build all projects
dotnet build

# Run tests (will have placeholders until Week 2-3)
dotnet test
```

### Clean Up Placeholders (Week 2 Priority)

### Clean Up Placeholders (Week 2 Priority)

**Domain Project:**

- Remove `NotImplementedException` from Certificate.cs, Machine.cs, MachineCertificate.cs
- Remove `NotImplementedException` from Thumbprint.cs (or delete if not using value object yet)
- Implement or delete CertificateNormalizer.cs, CertificateDeduplicator.cs, ExpiryEvaluator.cs

**Infrastructure Project:**

- Remove `NotImplementedException` from all adapter files
- Delete unused port interfaces until second implementation exists

**Application Project:**

- Remove `NotImplementedException` from use case files
- Implement or defer CollectionOrchestrator.cs

**Test Projects:**

- Delete `UnitTest1.cs` from all test projects
- Replace with real tests as features are implemented

```bash
# Find all NotImplementedException references
git grep -n "NotImplementedException"

# Delete placeholder test files
rm tests/Domain.Tests/UnitTest1.cs
rm tests/Application.Tests/UnitTest1.cs
rm tests/Infrastructure.Tests/UnitTest1.cs
```

---

## 📝 Next Immediate Actions

1. **Clean Up Placeholders** (30 minutes)
   - Remove NotImplementedException from all files OR delete placeholder methods
   - Delete UnitTest1.cs from all test projects
   - Commit cleanup: "chore: remove placeholder code from scaffold"

2. **Generate DDL Scripts** (Week 1, Task 2)
   - Create `docs/architecture/schema-ddl.sql`
   - Include all tables, indexes, constraints from v1-schema-analysis.md
   - Validate with SQL Server Management Studio

3. **Deploy Schema to Test SQL** (Week 1, Task 3)
   - Run DDL on test SQL Server
   - Validate all constraints and indexes

4. **Setup Azure Key Vault** (Week 1, Task 4)

   ```bash
   # Create Key Vault
   az keyvault create --name cambridgeinventory-test --resource-group inventory-rg --location eastus

   # Add secrets
   az keyvault secret set --vault-name cambridgeinventory-test --name "F5-ServiceAccount-Password" --value "your-password"
   az keyvault secret set --vault-name cambridgeinventory-test --name "SQL-ConnectionString" --value "Server=..."

   # Grant service account access
   az keyvault set-policy --name cambridgeinventory-test --object-id <service-principal-id> --secret-permissions get list
   ```

4. **Implement Domain Models** (Week 2)
   - Start with Certificate.cs (real properties, no placeholders)
   - Write first real unit tests in Domain.Tests

---

## 📅 Milestone Demonstrations

| Week | Phase | Milestone | Demo Content |
|------|-------|-----------|--------------|
| 4 | Phase 1 Exit | Foundation Working | Harvest 5 machines, show certificates in SQL, re-run harvest (LastVerified updates) |
| 8 | Phase 2 Exit | Production Scale | 50-machine harvest with IIS, injected SQL failure → buffer replay, parallel execution |
| 12 | Phase 3 Exit | Discovery & Lifecycle | AD sync results, soft delete lifecycle (missing → DeletedAt), recovery demonstration |
| 17 | Phase 4 Exit | Complete Sources | Full harvest (OS, IIS, F5, Repository), circuit breaker recovery, performance comparison |
| 22 | Phase 5 Exit | Self-Service UI | WebUI search, expiry dashboard, CSV export, pilot user feedback session |

---

**Hexagonal architecture is committed and ready for incremental population!** Phase 1 starts with DDL generation and domain model implementation.

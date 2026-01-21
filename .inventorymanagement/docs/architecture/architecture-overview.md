# Architecture Overview

**Last Updated:** November 20, 2025
**Status:** Approved & Implementation-Ready
**Owner:** Carl R. Yeager

---

## Executive Summary

The Cambridge Inventory Management System v2.0 is a **centralized infrastructure management platform** designed to collect, track, and analyze SSL/TLS certificates, Windows machines, and infrastructure metadata across 300+ servers. Built on a **full hexagonal architecture**, it replaces fragile v1.0 PowerShell scripts with a robust C# solution that supports future expansion to scheduled tasks, IIS configuration, Windows services, and compliance reporting.

**Core Innovation:** Central WinRM orchestrator eliminates distributed agent deployment while providing reliable, auditable collection with comprehensive traceability.

---

## Architectural Goals

### Primary Goals

1. **Reliability:** 99% collection success rate across all target servers
2. **Traceability:** Full audit trail for all certificate discovery, verification, and deletion events
3. **Operability:** Centralized monitoring, logging, and alerting via Serilog + Teams webhooks
4. **Security:** Credential-free design using service accounts + Azure Key Vault for secrets
5. **Extensibility:** Platform foundation supporting multi-year feature roadmap

### Non-Goals

- Real-time certificate monitoring (30-minute harvest interval is acceptable)
- Certificate provisioning or renewal automation (read-only inventory only)
- Replace existing PKI infrastructure (observability layer only)
- Support non-Windows certificate stores (Windows, F5, repository only)

---

## Quality Attributes

| Attribute | Requirement | Design Strategy |
|-----------|-------------|-----------------|
| **Reliability** | 99% uptime, graceful degradation | WinRM retry policies, SQLite buffering for SQL outages, soft delete with 90-day grace period |
| **Performance** | Complete 300-server harvest in < 30 minutes | 10 concurrent WinRM sessions, batched SQL MERGE operations, indexed queries |
| **Security** | No hardcoded credentials, least privilege | GMSA service account, Azure Key Vault integration, read-only WinRM access |
| **Traceability** | Full audit trail per certificate lifecycle | SQL logging table, structured Serilog, HarvestExecution tracking |
| **Maintainability** | Onboard new developer in < 2 days | Hexagonal architecture, comprehensive ADRs, separation of concerns |
| **Extensibility** | Add new collection source in < 1 week | Port/adapter pattern, isolated infrastructure layer |

---

## System Context

### Actors

- **Cambridge Inventory Service (Agent):** Scheduled background service orchestrating collection
- **SQL Server:** Persistent storage for certificates, machines, bindings, logs
- **Target Windows Servers (300+):** Remote systems exposing certificate stores via WinRM
- **F5 LTM Devices:** Load balancers exposing SSL profiles via REST API
- **Certificate Repository:** CIFS share containing archived PFX files
- **Azure Key Vault:** Secure secret storage for service account credentials
- **Microsoft Teams:** Alert destination for expiry warnings and failures

### System Boundaries

**What's Inside:**

- Certificate collection orchestration
- Machine registration and lifecycle tracking
- Data normalization and deduplication
- SQL persistence with MERGE upserts
- Soft delete and verification workflows
- Structured logging and health metrics

**What's Outside:**

- Certificate issuance/renewal (handled by PKI team)
- WinRM infrastructure provisioning (handled by Windows admins)
- SQL Server high availability (handled by DBA team)
- Network connectivity/firewall rules (handled by network team)

---

## Deployment Architecture

### Topology

```plaintext
┌─────────────────────────────────────────────────────────────┐
│  Management Server (Windows Server 2022)                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ Cambridge Inventory Agent (Windows Service)        │     │
│  │  ├─ Timer (30-minute interval)                     │     │
│  │  ├─ WinRM Workers (10 concurrent)                  │     │
│  │  ├─ F5 REST Client                                 │     │
│  │  ├─ Repository CIFS Reader                         │     │
│  │  └─ SQLite Buffer (local fallback)                 │     │
│  └────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
           │                    │                    │
           │ WinRM              │ HTTPS              │ SMB
           │ (5985/5986)        │ (443)              │ (445)
           ▼                    ▼                    ▼
    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
    │ Target       │    │ F5 LTM       │    │ Certificate  │
    │ Windows      │    │ Devices      │    │ Repository   │
    │ Servers      │    │ (REST API)   │    │ (PFX Share)  │
    │ (300+)       │    └──────────────┘    └──────────────┘
    └──────────────┘
           │
           │ SQL/TDS (1433)
           ▼
    ┌──────────────────────────────────┐
    │ SQL Server 2016+                 │
    │  ├─ ProdSpt_Inventory (DB)       │
    │  │   ├─ Certificates             │
    │  │   ├─ Machines                 │
    │  │   ├─ MachineCertificates       │
    │  │   ├─ HarvestExecutions         │
    │  │   └─ InventoryLogs             │
    │  └─ Azure Key Vault Integration  │
    └──────────────────────────────────┘
```

### Runtime Components

- **Agent (Windows Service):** .NET 9.0 Worker Service with BackgroundService scheduling
- **WinRM Clients:** PowerShell remoting sessions via `System.Management.Automation`
- **F5 REST Client:** HttpClient with rate limiting (1 req/sec per device)
- **SQL Persistence:** ADO.NET with parameterized MERGE statements
- **SQLite Buffer:** Lightweight fallback for SQL outages (local file storage)
- **Serilog:** Structured logging to console, file, and SQL

---

## Core Workflows

### 1. Machine Registration (Dynamic Discovery)

**Trigger:** First certificate discovered on a machine
**Flow:**

1. Agent harvests certificate from server `WEB-01`
2. Lookup `WEB-01` in `Machines` table by Hostname
3. If not exists: MERGE into `Machines` with Hostname, FQDN, Environment, FirstSeen
4. Return `MachineId` (surrogate key)
5. Use `MachineId` for `MachineCertificates` binding

**Invariants:**

- Hostname is unique per machine (constraint: `UQ_Machines_Hostname`)
- FQDN is optional (nullable)
- Environment auto-detected from domain suffix or explicit config

### 2. Certificate Harvest (OS/IIS/F5/Repository)

**Trigger:** Scheduled timer (30-minute interval)
**Flow:**

1. **Harvest Execution Created:** Insert row into `HarvestExecutions` with StartTime
2. **For Each Target Machine:**
   - Open WinRM session with retry (Polly policy: 3 attempts, exponential backoff)
   - Execute PowerShell: `Get-ChildItem Cert:\LocalMachine\My,Root,CA,AuthRoot`
   - Parse X509Certificate2 properties (Subject, Issuer, ValidFrom, ValidTo, etc.)
   - Close WinRM session
3. **Normalize & Deduplicate:**
   - Uppercase thumbprint, remove colons (e.g., `AB:CD:EF` → `ABCDEF`)
   - Group by thumbprint (multiple machines may share same cert)
4. **Persist to SQL:**
   - MERGE into `Certificates` (upsert by thumbprint)
   - MERGE into `Machines` (upsert by FQDN, returns MachineId)
   - MERGE into `MachineCertificates` (upsert by MachineId + Thumbprint + SourceType + PathLocation)
5. **On SQL Failure:** Buffer to SQLite (`PendingUploads` table)
6. **Update Harvest Execution:** Set EndTime, RecordCount, ErrorCount

**Concurrency:** 10 parallel WinRM sessions (SemaphoreSlim throttling)

### 3. Soft Delete & Verification Cycle

**Trigger:** Certificate no longer found in subsequent harvest
**Flow:**

1. **During Harvest:** Cert `ABC123` previously seen on `WEB-01` in `LocalMachine\My`
2. **Current Scan:** Cert `ABC123` NOT found in `LocalMachine\My`
3. **Soft Delete:** Update `MachineCertificates` SET `DeletedAt = GETUTCDATE()`, `IsDeleted = 1`
4. **Grace Period:** Retain for 90 days (ADR-004)
5. **Verification:** If cert reappears (false positive deletion), clear `DeletedAt` and `IsDeleted`
6. **Hard Delete (Optional):** After 90 days, move to `MachineCertificates_History` or purge

---

## Layer & Hexagonal Mapping

### Project → Hexagonal Role

| Project | Hexagonal Role | Ports | Adapters | Dependencies |
|---------|----------------|-------|----------|--------------|
| **Domain** | Core business logic | `ICertificateStoreReader`, `IIngestionWriter`, `IF5RestClient` | None (pure) | None |
| **Application** | Use case orchestration | Defines ports | None | Domain only |
| **Infrastructure** | External system adapters | None | `WinRmCertificateCollector`, `SqlServerPersistence`, `F5RestClient`, `TeamsWebhookPublisher` | Domain only |
| **Agent** | Hosting & composition root | None | None | Application, Infrastructure |
| **Domain.Tests** | Unit tests | N/A | N/A | Domain only |
| **Application.Tests** | Use case tests | N/A | Mocked ports | Application, Domain |
| **Infrastructure.Tests** | Integration tests | N/A | Real adapters | Infrastructure, Domain |

### Dependency Flow (Enforced)

```plaintext
Agent → Application → Domain
  ↓           ↓
Infrastructure ──────→ Domain

(Agent and Infrastructure both depend on Domain; Application orchestrates)
```

**Forbidden Dependencies:**

- ❌ Domain → Infrastructure (violates dependency inversion)
- ❌ Domain → Application (core cannot depend on use cases)
- ❌ Infrastructure → Application (adapters don't orchestrate)

---

## Data Model Summary

### Core Tables

**`Certificates`** (Canonical store)

- **Purpose:** Deduplicated certificate data
- **Primary Key:** `CertificateId` (surrogate)
- **Unique Key:** `Thumbprint` (SHA-1, 40 hex chars)
- **Key Columns:** Subject, Issuer, ValidFrom, ValidTo, SANs (JSON), HasPrivateKey

**`Machines`** (Dynamic inventory)

- **Purpose:** Track Windows servers and environments
- **Primary Key:** `MachineId` (surrogate)
- **Unique Key:** `FQDN`
- **Key Columns:** Hostname (unique), FQDN (nullable), Environment (enum), Roles (JSON), FirstSeen, LastSeen, IsActive

**`MachineCertificates`** (Many-to-many binding)

- **Purpose:** Track certificate locations and usage contexts
- **Primary Key:** `MachineCertificateId` (surrogate, ADR-007)
- **Unique Constraint:** `(MachineId, Thumbprint, SourceType, PathLocation)`
- **Key Columns:** BindingContext (JSON), DateDiscovered, LastVerified, DeletedAt (soft delete)

**`HarvestExecutions`** (Run tracking)

- **Purpose:** Audit trail for collection runs
- **Primary Key:** `HarvestExecutionId`
- **Key Columns:** StartTime, EndTime, SourceType, RecordCount, ErrorCount

**`InventoryLogs`** (Structured logging)

- **Purpose:** Centralized logging table (Serilog sink)
- **Key Columns:** Timestamp, Level, Message, Exception, Properties (JSON)

### Key Invariants

Business invariants are defined in `domain-architecture.md` (entity validation rules); persistence constraints are defined in `data-model-design.md` (DB-enforced rules, unique constraints, soft delete columns).

For full schema DDL: See `docs/architecture/schema-ddl.sql`
For design rationale: See `docs/architecture/data-model-design.md`

---

## Decision Index

| ADR | Title | Rationale |
|-----|-------|-----------|
| **001** | Central WinRM Orchestrator | Single management point vs 300 distributed agents; WinRM already enabled |
| **002** | Full Hexagonal Architecture | Multi-year platform supporting Phase 3 WebUI + future features; scaffold already committed |
| **003** | Conditional SQLite Buffering | Lightweight resilience for SQL outages without over-engineering state machines |
| **004** | Soft Delete with 90-Day Grace | Prevent accidental data loss from transient scan failures; retain audit trail |
| **005** | Service Account + Azure Key Vault | GMSA for agent identity; Key Vault for F5/SQL secrets; no hardcoded credentials |
| **006** | Machine Registration via MERGE | Dynamic discovery without pre-provisioning; upsert pattern for idempotency |
| **007** | Surrogate Key for MachineCertificates | Supports multiple PathLocations per cert/machine; unique constraint on business key |
| **008** | Phased Delivery Timeline | 5 phases (22 weeks): Weeks 1-4, 5-8, 9-12, 13-17, 18-22; incremental validation gates |
| **009** | Machine Discovery via Dedicated Worker | Multiple BackgroundService workers for separate concerns; AD sync decoupled from cert harvesting |

**Full ADR Details:** See `docs/architecture/architectural-decisions.md`

---

## Extension & Evolution Strategy

### Adding New Collection Sources

**Pattern:** Implement new adapter in Infrastructure layer

**Example: AWS ACM Certificates**

1. **Define Port** (in Domain):

   ```csharp
   public interface IAwsAcmClient
   {
       Task<Certificate[]> ListCertificatesAsync(string region, CancellationToken ct);
   }
   ```

2. **Implement Adapter** (in Infrastructure):

   ```csharp
   public class AwsAcmClient : IAwsAcmClient
   {
       // AWS SDK integration
   }
   ```

3. **Register in Agent**:

   ```csharp
   services.AddSingleton<IAwsAcmClient, AwsAcmClient>();
   ```

4. **Add Worker**:

   ```csharp
   public class AwsCertificateWorker : BackgroundService
   {
       private readonly IAwsAcmClient _acmClient;
       private readonly IIngestionWriter _writer;
       // Harvest logic
   }
   ```

**No changes required to Domain models or Application use cases.**

### Adding New Features

- **Scheduled Tasks Inventory:** New worker + adapter for `Get-ScheduledTask`
- **IIS Configuration:** Extend existing WinRM adapter with `Get-WebSite` cmdlets
- **Compliance Reports:** New use case in Application layer consuming existing Domain entities
- **WebUI (Phase 3):** ASP.NET Core project sharing Domain + Infrastructure

---

## Cross-Cutting Concerns

### Security Architecture

- **Identity:** GMSA (Group Managed Service Account) for Agent service
- **Secrets:** Azure Key Vault integration for F5 passwords, SQL connection strings
- **Network:** WinRM over Kerberos authentication; HTTPS for F5 REST API
- **Least Privilege:** Read-only WinRM access; SQL user limited to MERGE/SELECT

### Resilience Architecture

- **Retry Policies:** Polly with exponential backoff (WinRM: 3 attempts, F5: 5 attempts)
- **Circuit Breaker:** F5 REST client trips after 5 consecutive failures
- **Buffering:** SQLite fallback for SQL Server outages (max 7 days retention)
- **Graceful Degradation:** Continue harvesting available servers if subset fails

### Observability Architecture

- **Structured Logging:** Serilog with sinks to Console, File, SQL (`InventoryLogs`)
- **Metrics:** HarvestExecution records (success rate, duration, error count)
- **Alerting:** Teams webhook on critical errors or expiry warnings
- **Correlation:** HarvestExecutionId propagated through all log entries

---

## Current Phase & Roadmap

**Current Status:** Architecture finalized, ready for Phase 1 implementation

**Phase 1 (Weeks 1-4):** Foundation & Basic OS Harvest

- Domain models + SQL persistence + sequential WinRM OS collector
- Manual machine registration, basic logging
- Deliverable: 5-10 machine OS cert harvest operational

**Phase 2 (Weeks 5-8):** Scale & Resilience

- Parallel WinRM execution + IIS binding collection
- HarvestExecution tracking + SQLite buffer + Serilog SQL sink
- Deliverable: Production-scale 300-server harvest with resilience

**Phase 3 (Weeks 9-12):** Machine Discovery & Lifecycle

- AD sync (MachineDiscoveryWorker) + soft delete lifecycle
- Recovery logic + machine-level soft delete
- Deliverable: Automated discovery and certificate lifecycle management

**Phase 4 (Weeks 13-17):** F5 & Repository Integration

- F5 REST client (auth, rate limiting, circuit breaker)
- Repository PFX scanner (CIFS read-only)
- Deliverable: Complete inventory across all 4 sources (OS, IIS, F5, Repository)

**Phase 5 (Weeks 18-22):** WebUI & Reporting

- ASP.NET Core WebUI + search + expiry dashboard
- CSV export + alert subscriptions (read-only UI)
- Deliverable: Production-ready self-service platform

**For detailed tasks:** See `docs/planning/implementation-roadmap.md`

---

## Glossary

| Term | Definition |
|------|------------|
| **Harvest** | Scheduled collection run gathering certificates from all configured sources |
| **BindingContext** | JSON blob storing source-specific metadata (e.g., IIS site name, F5 virtual server) |
| **PathLocation** | Certificate store path (e.g., `LocalMachine\My`, `CurrentUser\Root`) |
| **Soft Delete** | Marking record as deleted without physical removal; grace period = 90 days |
| **MERGE** | SQL upsert pattern (INSERT if not exists, UPDATE if exists) for idempotent persistence |
| **WinRM** | Windows Remote Management (PowerShell remoting protocol) |
| **GMSA** | Group Managed Service Account (Windows identity for services, no password management) |
| **Surrogate Key** | Synthetic primary key (e.g., `MachineId`) independent of business data |

---

## Authoritative Sources

| Topic | Source of Truth | When to Reference |
|-------|----------------|-------------------|
| System goals, workflows, phase roadmap | `architecture-overview.md` (this doc) | Onboarding, stakeholder reviews |
| Architectural decisions (ADRs) | `architectural-decisions.md` | Before changing design constraints |
| Business invariants, entity rules | `domain-architecture.md` | Validating domain logic, entity design |
| Use case orchestration patterns | `application-architecture.md` | Building/reviewing use cases |
| Adapter design, resilience patterns | `infrastructure-architecture.md` | Implementing external integrations |
| Hosting & DI composition | `agent-architecture.md` | Service configuration, worker registration |
| Schema design, persistence rules | `data-model-design.md` | Writing migrations, DB constraints |
| Phase scope, tasks, acceptance | `planning/phase-X-plan.md` | Sprint planning, progress tracking |
| Risk tracking | `planning/risk-register.md` | Risk reviews, mitigation planning |
| Test strategy, coverage goals | `planning/testing-strategy.md` | Writing tests, CI configuration |
| Metrics definitions, KPIs | `planning/metrics-and-kpis.md` | Building dashboards, alerts |
| Implementation tactics | `planning/implementation-decisions.md` | Code review, tactical choices |
| Executable schema | `architecture/schema-ddl.sql` | Database deployment, migrations |

**Policy:** Each document is the single source of truth for its topic. Other documents summarize (1–2 sentences max) and link—never duplicate detail.

---

## Related Documents

- **Architecture:** `architectural-decisions.md` (ADRs), `data-model-design.md`, component architecture docs
- **Planning:** `docs/planning/implementation-roadmap.md`, phase plans
- **Implementation:** `docs/implementation/developer-guide.md`, setup guides
- **Reference:** `docs/architecture/schema-ddl.sql`, interface catalog
- **Historical:** `docs/architecture/archive/*-SUPERSEDED.md`

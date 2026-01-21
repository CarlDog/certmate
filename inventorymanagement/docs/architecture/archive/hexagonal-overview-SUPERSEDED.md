# Hexagonal Architecture Overview

## Introduction

The Cambridge Inventory Management system uses a **full hexagonal (ports and adapters) architecture** to support its evolution from certificate collection to comprehensive infrastructure management platform.

**See `architectural-decisions.md` for all approved ADRs, especially ADR-002.**

## Architectural Foundation (Committed)

### Complete Hexagonal Structure

**7 Projects (All Committed):**

1. **`Domain`** (Class Library) - Pure business logic, zero dependencies
2. **`Application`** (Class Library) - Use case orchestration
3. **`Infrastructure`** (Class Library) - External system adapters
4. **`Agent`** (Windows Service) - Hosting and composition root
5. **`Domain.Tests`** (xUnit) - Pure unit tests
6. **`Application.Tests`** (xUnit) - Use case tests with mocked ports
7. **`Infrastructure.Tests`** (xUnit) - Adapter integration tests

**Phase 3 Addition:**
8. **`InventoryWeb`** (ASP.NET Core) - WebUI sharing Domain/Infrastructure

### Why Full Hexagonal Architecture?

**ADR-002 Decision:** This is a **platform, not a script**.

**Justification:**

- **Multi-year vision:** "Build onto, layer by layer, for managing and tracking our infrastructure and the metadata of our application deployments"
- **Multiple consumption models:** Agent (scheduled collection) + WebUI (reports/exports) + Future API
- **Shared persistence:** Both Agent and WebUI need same SQL access patterns
- **Feature expansion planned:** Scheduled tasks, IIS inventory, Windows services, compliance reporting
- **Scaffold already complete:** 47 files committed, builds cleanly, organized structure in place

**This is NOT YAGNI because:**

- Phase 3 WebUI confirmed (will share Domain/Infrastructure)
- Additional inventory types planned (scheduled tasks, services, IIS)
- Multiple consuming applications anticipated
- Cost already paid (committed scaffold)

## Core Principles (Still Applied)

### 1. Separation of Concerns

- Collection logic separate from hosting/scheduling
- SQL persistence isolated in dedicated classes
- Configuration bound via typed objects

### 2. Testability

- WinRM calls mockable via interfaces (minimal abstraction)
- SQL logic testable with Testcontainers or LocalDB
- Domain models are POCOs (no dependencies)

### 3. PULL-ONLY Collection (ADR-001)

- Central Windows Service orchestrates collection
- WinRM remoting to target servers (no agents deployed)
- F5 accessed via REST API
- Repository accessed via CIFS share

## Data Flow (Central Orchestrator Model)

```plaintext
Timer (InventoryAgent)
  → Worker.ExecuteAsync()
    → foreach (machine in targetMachines)
      → WinRmCertificateCollector.CollectAsync(machine)
        → PowerShell Remoting (Get-ChildItem Cert:\)
        → Parse X509Certificate2 properties
        → Return Certificate[] + Machine
      → SqlServerPersistence.UpsertAsync(certificates, machine)
        → MERGE INTO Certificates
        → MERGE INTO Machines (returns MachineId)
        → MERGE INTO MachineCertificates
      → (on SQL failure) SqliteBuffer.BufferAsync(certificates)
```

## Configuration Strategy

Configuration flows from `appsettings.json` + Azure Key Vault:

```json
{
  "AzureKeyVault": {
    "VaultUri": "https://cambridgeinventory.vault.azure.net/"
  },
  "WinRM": {
    "MaxConcurrency": 10,
    "TargetServers": ["WEB-01", "WEB-02", "..."]
  },
  "F5": {
    "Devices": ["f5-prod-01.example.com"],
    "Username": "svc.f5.readonly",
    "PasswordSecretName": "F5-ServiceAccount-Password"
  },
  "Sql": {
    "ConnectionString": "Server=...;Database=ProdSpt_Inventory;..."
  }
}
```

Secrets (F5 password, etc.) fetched from Key Vault at startup via Managed Identity (ADR-005).

## Testing Strategy

- **Unit Tests:** Collection logic, normalization, MERGE statement generation
- **Integration Tests:** WinRM with test server, SQL with Testcontainers
- **Manual Validation:** Pilot deployment to 10 servers, compare vs v1.0 data

---

## Future Architecture (Phase 3+)

### If Hexagonal Architecture Becomes Necessary

**Trigger Conditions:**

- Multiple consuming applications (API, WebUI, CLI)
- Second persistence implementation (e.g., caching layer, audit log)
- Complex domain logic (certificate chain validation, compliance policies)

**Potential Layering:**

- **Domain:** Pure models, interfaces (ports)
- **Application:** Use cases, orchestration
- **Infrastructure:** Adapters (SQL, WinRM, F5, Teams)
- **Agent/Web:** Hosting and driving adapters

**Migration Path:**

1. Extract interfaces from concrete classes (IWinRmCollector, ISqlPersistence)
2. Move models to separate Domain project
3. Move adapters to Infrastructure project
4. Move orchestration to Application project
5. Update DI registration

**Estimated Effort:** 2-3 days if triggered after Phase 2.

---

## Layer Responsibilities

### Domain (`src/Domain`)

**Purpose:** Pure business logic and domain model
**Dependencies:** None (pure C#)
**Contains:**

- **Entities:** Certificate, Machine, MachineCertificate
- **Value Objects:** Thumbprint (when complexity justifies)
- **Domain Services:** CertificateNormalizer, CertificateDeduplicator, ExpiryEvaluator
- **Port Interfaces:** ICertificateStoreReader, IIngestionWriter, IF5RestClient, ITeamsNotifier, IClock

**Rules:**

- No external dependencies (no NuGet packages except primitives)
- No I/O operations (all via port interfaces)
- Framework-agnostic (no ASP.NET, no Entity Framework)

### Application (`src/Application`)

**Purpose:** Use case orchestration and application logic
**Dependencies:** Domain only
**Contains:**

- **Use Cases:** LocalCertificates, HarvestRemoteCertificatesUseCase, SendWeeklyDigest
- **Command Handlers:** ICertificateCollectionCommand
- **Orchestrators:** CollectionOrchestrator (coordinates multiple use cases)

**Rules:**

- Orchestrate domain services and port calls
- No direct database/HTTP/file access (use ports)
- Testable with mocked ports

### Infrastructure (`src/Infrastructure`)

**Purpose:** External system adapters and technical concerns
**Dependencies:** Domain (implements ports)
**Contains:**

- **Persistence:** SqlServerPersistence, SqliteBuffer, SqlLogger
- **Certificate Stores:** WindowsCertStoreReader, RemoteWinRmCertCollector, RepositoryPfxReader
- **External Clients:** F5RestClient, TeamsWebhookPublisher
- **Cross-Cutting:** PolicyFactory (Polly retry/rate limiting), SecretsProvider (Key Vault)

**Rules:**

- Implements Domain port interfaces
- Contains all external dependencies (NuGet packages)
- Swappable without Domain changes

### Agent (`src/Agent`)

**Purpose:** Hosting, scheduling, and composition root
**Dependencies:** Application, Infrastructure
**Contains:**

- **Worker:** BackgroundService with scheduled harvests
- **DI Registration:** ServiceRegistration (wires ports to adapters)
- **Configuration Binding:** SqlConfiguration, F5Configuration, etc.
- **Logging Setup:** Serilog (console + file + SQL)

**Rules:**

- Only place where Application and Infrastructure meet
- All DI registration happens here
- No business logic (just wiring)

## Data Flow (Central Orchestrator Model)

```plaintext
Timer (Agent)
  → Worker.ExecuteAsync()
    → CollectionOrchestrator (Application)
      → HarvestRemoteCertificatesUseCase (Application)
        → ICertificateStoreReader port (Domain interface)
          ← RemoteWinRmCertCollector adapter (Infrastructure)
            ← PowerShell Remoting → Target Servers
        → IIngestionWriter port (Domain interface)
          ← SqlServerPersistence adapter (Infrastructure)
            ← SQL Server (MERGE upserts)
        → (on SQL failure) SqliteBuffer adapter (Infrastructure)
            ← Local SQLite buffer.db
```

## Guard Rails (Prevent Over-Engineering)

**ADR-002 Conditions:**

1. ✅ **No NotImplementedException** - All placeholder code removed or implemented
2. ✅ **Interfaces when needed** - Delete unused ports until second implementation exists
3. ✅ **Real tests or no tests** - Test projects populated or removed (no empty shells)
4. ✅ **Document intent** - README explains incremental population
5. ✅ **Validate value** - If layer becomes pure pass-through, collapse it

## Incremental Population Strategy

**Phase 1 (Weeks 1-8): Core Collection**

- Domain: Certificate, Machine, MachineCertificate entities (full properties)
- Infrastructure: SqlServerPersistence, RemoteWinRmCertCollector, SqliteBuffer
- Agent: Worker with WinRM orchestration, DI registration
- Tests: SqlPersistenceTests, WinRmCollectorTests

**Phase 2 (Weeks 9-14): F5 & Repository**

- Application: CollectionOrchestrator (coordinates OS + F5 + Repo)
- Infrastructure: F5RestClient, RepositoryPfxReader, PolicyFactory (rate limiting)
- Domain Services: ExpiryEvaluator, CertificateDeduplicator
- Tests: F5ClientTests, PolicyFactoryTests

**Phase 3 (Weeks 15-20): WebUI**

- InventoryWeb: Razor Pages/Blazor, shares Domain/Infrastructure
- Application: ReportingUseCase (queries for WebUI)
- Infrastructure: No changes needed (reuse SqlServerPersistence)

## Configuration Strategy

Configuration flows from `appsettings.json` + Azure Key Vault through DI:

```json
{
  "AzureKeyVault": {
    "VaultUri": "https://cambridgeinventory.vault.azure.net/"
  },
  "WinRM": {
    "MaxConcurrency": 10,
    "TargetServers": ["WEB-01", "WEB-02", "..."]
  },
  "F5": {
    "Devices": ["f5-prod-01.example.com"],
    "Username": "svc.f5.readonly",
    "PasswordSecretName": "F5-ServiceAccount-Password"
  },
  "Sql": {
    "ConnectionString": "Server=...;Database=ProdSpt_Inventory;..."
  }
}
```

Agent binds configuration models → ServiceRegistration wires adapters with config → Adapters receive typed configuration objects.

## Testing Strategy

- **Domain.Tests:** Pure unit tests (no I/O, no mocks needed)
- **Application.Tests:** Use case tests with mocked ports (verify orchestration)
- **Infrastructure.Tests:** Adapter tests with Testcontainers or ephemeral resources
- **Integration:** End-to-end validation in lab environment (Agent → WinRM → SQL)

## Related Documents

- `architectural-decisions.md` - All ADRs (ADR-001 through ADR-009)
- `archive/ports-and-adapters-SUPERSEDED.md` - Archived draft (specs now expressed via ADRs + code interfaces)
- `v1-schema-analysis.md` - v1.0 analysis and v2.0 schema design
- `archive/architectural-review-SUPERSEDED.md` - Archived critical analysis (superseded by PRE-IMPLEMENTATION-REVIEW.md)

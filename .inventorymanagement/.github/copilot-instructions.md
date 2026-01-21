# Cambridge Inventory Management: Copilot AI Agent Instructions

## 🏗️ Project Context & Architecture

-   **System:** Centralized infrastructure management platform for SSL/TLS certificates and machine inventory.
-   **Architecture:** **Hexagonal Architecture (Ports & Adapters)**.
    -   **Domain:** Pure C# business logic, entities, value objects, and port interfaces. No external dependencies.
    -   **Application:** Use cases, orchestration, and application-specific ports. Depends on Domain.
    -   **Infrastructure:** Adapters for SQL, WinRM, F5, Files, etc. Implements ports. Depends on Domain/Application.
    -   **Agent:** Windows Service host, Composition Root (DI), Configuration. Depends on all.
-   **Tech Stack:** .NET 9.0, C#, SQL Server, PowerShell (legacy/prototyping), WinRM.
-   **Key Pattern:** **Centralized WinRM Orchestrator**. Pull-based collection from 300+ servers. No remote agents.
-   **Migration Context:** Replacing v1.0 PowerShell scripts (in `v1.0/` folder) with robust C# architecture.

## 🔗 Quick Links

-   `docs/README.md` – documentation index + navigation guidance
-   `planning/implementation-roadmap.md` – delivery timeline and phase status
-   `docs/implementation/implementation-tracker.md` – phase/stage progress, acceptance criteria, blockers
-   `docs/implementation/1-phase-one/` – Stage-by-stage execution guides (current phase)

## 📂 Codebase Structure

-   `src/Domain/`: Enterprise logic. **Start here** for business rules.
    -   Entities: `Certificate`, `Machine`, `MachineCertificate`
    -   Domain Services: `CertificateNormalizer`, `ExpiryEvaluator`
    -   Port Interfaces: `ICertificateStoreReader`, `IIngestionWriter`, `IF5RestClient`
-   `src/Application/`: Orchestration logic. Defines _what_ the system does.
    -   Use Cases: `LocalCertificates`, `SendWeeklyDigest`
    -   Orchestrators: `CollectionOrchestrator`
-   `src/Infrastructure/`: Implementation details. Defines _how_ it connects to the world.
    -   Adapters: `WinRmOSCollector`, `SqlServerPersistence`, `F5RestClient`
    -   Policies: Polly retry/rate-limiting configurations
-   `src/Agent/`: Entry point. `Program.cs` (DI), `Worker.cs` (BackgroundService).
-   `tests/`: xUnit test projects mirroring the source structure (`Domain.Tests`, etc.).
-   `v1.0/`: Legacy PowerShell scripts (reference only - **do not modify**).
-   `scripts/`: New operational utilities (deployment, diagnostics).
-   `docs/`: **Single Source of Truth** for all documentation.

## 🚀 Development Workflow

-   **Build:** Use the dotnet build task or dotnet build in terminal.
-   **Test:** Use the dotnet test task or dotnet test in terminal.
-   **Run:** Use dotnet run --project src/Agent to start the service locally.
-   **Database:** Schema DDL is in src/Infrastructure/Persistence/Schema/. Use sqlcmd or SSMS to deploy.
-   **Legacy Scripts:** PowerShell 5.1 scripts in `v1.0/` are for reference/migration only. Do not modify unless explicitly asked.

## 📏 Key Conventions

-   **Dependency Injection:** All services must be registered in `src/Agent/Program.cs`. Use Constructor Injection.
-   **Logging:** Use **Serilog**. Inject `ILogger<T>`. Structured logging is mandatory (e.g., `Log.Information("Harvesting {Machine}", machineName)`).
-   **Configuration:** Use `appsettings.json` and `IOptions<T>`. Secrets go in Azure Key Vault (dev: User Secrets).
-   **Error Handling:**
    -   **Domain:** Use Result pattern or specific Domain Exceptions.
    -   **Infrastructure:** Use **Polly** for retries (WinRM, SQL, F5).
    -   **Global:** Top-level try/catch in Worker loop to prevent service crash.
-   **Data Access:**
    -   Use `Microsoft.Data.SqlClient`.
    -   **MERGE Statements:** All upserts must use SQL MERGE for idempotency.
    -   **No EF Core:** Raw SQL or Dapper (if approved) for performance.
-   **Testing:**
    -   **Domain.Tests:** Pure unit tests, no mocking needed (pure functions).
    -   **Application.Tests:** Use case tests with mocked ports (Infrastructure interfaces).
    -   **Infrastructure.Tests:** Integration tests with Testcontainers for SQL Server (requires local Docker/Testcontainers support).

## 📚 Documentation Standards

-   **Master Tracker:** `docs/implementation/implementation-tracker.md` tracks ALL progress. **Check this first.**
-   **Phase Guides:** Follow `docs/implementation/X-phase-name/` for specific implementation steps.
-   **Architecture:** Refer to `docs/architecture/` for design decisions (ADRs).
-   **Doc Index:** Use `docs/README.md` for navigation + authoritative locations.
-   **Roadmap:** Align tasks with `planning/implementation-roadmap.md` milestones.
-   **Update Rule:** If you change code that affects architecture or planning, **you must update the documentation**.

## 🎨 Code Organization Principles

-   **Domain Layer Purity:** No external dependencies. No NuGet packages (except core BCL).
-   **Dependency Rule:** Dependencies point inward (Infrastructure → Application → Domain).
-   **Port/Adapter Pattern:** Define interfaces (ports) in Domain, implement (adapters) in Infrastructure.
-   **No NotImplementedException:** Delete placeholder methods or implement them. No stubs in main branch.
-   **Guard Rails:**
    -   Interfaces only when second implementation exists or is planned (Phase 3 WebUI).
    -   Real tests or no test projects - no empty test files.
    -   Document architectural intent in README when scaffold exceeds current needs.

## 🎯 Current Focus: Phase 1 (Foundation & Basic OS Harvest)

-   **Goal:** Reliable OS certificate harvest from 5-10 machines.
-   **Critical Components:**
    -   `WinRmOSCollector` (Infrastructure)
    -   `CertificateCollectionWorker` (Agent)
    -   `SqlServerPersistence` (Infrastructure)
-   **Status:** See `docs/implementation/implementation-tracker.md`.
-   **Phase Guide:** Work through `docs/implementation/1-phase-one/phase-1-stage-1-foundation.md` → `phase-1-stage-5-hardening.md` for ordered implementation steps.

## 🔑 Key Architectural Decisions (ADRs)

-   **ADR-001:** Central WinRM orchestrator (no remote agents).
-   **ADR-002:** Full hexagonal architecture with incremental population.
-   **ADR-003:** Conditional SQLite buffering for SQL outages.
-   **ADR-004:** Soft delete with 90-day grace period.
-   **ADR-005:** Service account + Azure Key Vault for credentials.
-   **ADR-006:** Machine registration via MERGE upsert.
-   **ADR-007:** MachineCertificates uses surrogate key + PathLocation.
-   **ADR-008:** 5-phase delivery plan (22 weeks total).
-   **ADR-009:** Throttling strategies (10 concurrent WinRM, 5 rps F5).
-   **Full details:** `docs/architecture/architectural-decisions.md`

## 🚨 Critical Constraints

-   **Concurrency Limits:** Max 10 concurrent WinRM sessions, 5 requests/sec to F5.
-   **Performance Target:** Complete 300-server harvest in < 30 minutes.
-   **Security:** No hardcoded credentials. A proper Windows Service Account + Azure Key Vault integration must be used for all secrets management. GMSA was originally considered, but has been rejected due to the fact that BIG-IP F5 devices do not support Kerberos authentication, which is a requirement for GMSA to function correctly. Therefore, traditional service accounts with secure password management via Azure Key Vault will be utilized to ensure compatibility and security.
-   **Data Integrity:** All upserts via MERGE. Idempotent operations only.
-   **Observability:** Structured logging to SQL (`InventoryLogs` table) + file sinks.

---

## 🧰 Technology Usage Guidance

-   **Primary Development:** Implement new functionality in C# (`src/Domain`, `src/Application`, `src/Infrastructure`, `src/Agent`).
-   **scripts/** folder: Use for new operational utilities (deployment, diagnostics) when C# is impractical (e.g., admin automation). Keep scripts modern PowerShell and reference C# services rather than duplicating logic.
-   **v1.0/** folder: Legacy PowerShell for reference only. **Do not edit** unless explicitly migrating code; instead replicate behavior in C#.
-   When parity with legacy behavior is required, read the relevant v1.0 script, document the intent in the corresponding Phase guide, then re-implement via ports/adapters.
-   Never introduce new dependencies on legacy SQL tables or logging patterns without validating against ADRs + roadmap.

---

**Reminders:**

-   Always prefer **C# .NET 9.0** solutions over PowerShell for new features.
-   Keep the **Domain** pure (no NuGet packages unless absolutely necessary).
-   Use **Interfaces** (Ports) for all external dependencies to ensure testability.
-   Check `docs/implementation/implementation-tracker.md` before starting any work.

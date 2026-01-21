# Agent Architecture

**Last Updated:** November 20, 2025
**Status:** Draft – Sections marked TODO will be completed during Phase 1.
**Owner:** Carl R. Yeager

---

## Purpose & Design Intent

The **Agent** is a .NET 9.0 Windows Service that hosts the certificate collection workers. It is the **composition root** for dependency injection and configuration.

**Key Responsibility:** "Where the system runs and how components are wired together."

---

## Architectural Responsibilities

### What Agent Owns

- BackgroundService workers (scheduled harvesting)
- Dependency injection container (ServiceCollection)
- Configuration binding (appsettings.json + Azure Key Vault)
- Serilog logging configuration (console, file, SQL)
- Health checks and metrics
- Service lifetime management

### What Agent Does NOT Own

- Business logic (Domain responsibility)
- Use case orchestration (Application responsibility)
- Adapter implementations (Infrastructure responsibility)

---

## Design Constraints

1. **Depends on Application + Infrastructure:** Wires them together via DI
2. **No Business Logic:** Pure composition and hosting
3. **Windows Service Only:** No ASP.NET, no HTTP endpoints (until Phase 3 WebUI)

---

## Key Abstractions

**TODO:** Populate during Phase 1 implementation (Weeks 1-2)

**Expected Workers:**

- `CertificateCollectionWorker : BackgroundService` (30-minute timer)
- `MachineDiscoveryWorker : BackgroundService` (AD sync, daily)
- Future: `IISInventoryWorker`, `ScheduledTaskWorker`

**Expected Configuration Classes:**

- `SqlConfiguration`
- `F5Configuration`
- `WinRmConfiguration`
- `InventoryConfiguration`
- `HarvestConfiguration`
- `AzureKeyVaultConfiguration`
- `TargetServers` (simple array binding via configuration manager)

## Configuration & Secrets Management

- `src/Agent/appsettings.json` is the sanitized baseline committed to source control. It now documents SQL connectivity, WinRM concurrency, harvest cadence, manual target servers (5 pilot hosts), F5 placeholders, and Serilog sinks (console + rolling file).
- Developers overlay values with `appsettings.Development.json` (gitignored) or `dotnet user-secrets`. The example file (`appsettings.Development.json.example`) shows how to wire secrets locally without ever checking them in.
- The `AzureKeyVault` section toggles runtime secret loading. When `Enabled = true`, `Program.cs` adds Key Vault as a configuration source using managed identity by default, or a client secret supplied via user secrets for non-Azure environments.
- Typed options are bound in `ServiceRegistration.AddInventoryServices`, which validates `Sql`, `WinRM`, `F5`, `Harvest`, `Inventory`, and `AzureKeyVault` sections on startup. This keeps the Agent fail-fast if a required key is missing.
- Serilog is configured through configuration only (no hardcoded sinks). Output templates explicitly surface `Machine`, `HarvestCycleId`, and `CertificateCount` structured properties so downstream log processing can correlate harvest operations.
- Manual machine onboarding for Phase 1 is managed through the `TargetServers` array. Later discovery workers will hydrate this list automatically, but retaining the section provides an operational escape hatch.

---

## Collaboration Patterns

**TODO:** Add after implementation

---

## Failure & Resilience Design

**Agent Responsibilities:**

- Unhandled exception logging (top-level try/catch in workers)
- Service restart on critical failures
- Health check endpoints (if Phase 3 adds HTTP listener)

---

## Testing Strategy

**TODO:** Populate during Phase 1

**Note:** Agent typically not unit-tested (composition root); validated via integration tests.

---

## Extension Points

**Adding New Workers:**

1. Implement `BackgroundService`
2. Register in `Program.cs`: `services.AddHostedService<NewWorker>()`
3. Inject dependencies via constructor

---

## Related Documents

- **Application Architecture:** `application-architecture.md`
- **Infrastructure Architecture:** `infrastructure-architecture.md`

---

## Related ADRs

| ADR | Topic | Agent Concern |
|-----|-------|---------------|
| 001 | Central WinRM Orchestrator | Hosts orchestrated workers executing WinRM collectors |
| 002 | Hexagonal Architecture | Enforces composition root boundaries & dependency direction |
| 003 | Conditional SQLite Buffering | Coordinates enabling/disabling buffer via configuration |
| 005 | Service Account & Key Vault | Agent config & secret retrieval wiring |
| 008 | Phased Delivery Timeline | Drives worker rollout sequencing |
| 009 | Dedicated Discovery Worker | Introduces multiple BackgroundService registrations |

# .NET Scaffold Overview: Inventory Management (Hexagonal)

This document summarizes the current .NET scaffold and how it maps to the approved hexagonal architecture and operational constraints.

## Solution Layout

- Solution: `InventoryManagement.sln`
- Projects:
  - `src/Domain` (Class Library)
    - Purpose: Enterprise/business domain types, value objects, aggregates, domain services, and port interfaces.
    - Dependencies: None (pure C#). Targets `net9.0`.
  - `src/Application` (Class Library)
    - Purpose: Use cases, orchestration, and application ports (interfaces) that the infrastructure implements.
    - Depends on: `Domain`.
  - `src/Infrastructure` (Class Library)
    - Purpose: Adapters for persistence (SQL), remote access (WinRM, F5 REST), file system, and external services.
    - Depends on: `Domain`.
    - NuGet: `Microsoft.Data.SqlClient`, `Polly`.
  - `src/Agent` (Worker Service)
    - Purpose: Host and scheduling; DI composition root; Windows Service packaging; logging.
    - Depends on: `Application`, `Infrastructure`.
    - NuGet: `Serilog.AspNetCore`, `Serilog.Sinks.File`, `Microsoft.Extensions.Hosting.WindowsServices (9.0.0)`.
  - `tests/Domain.Tests` (xUnit)
    - Purpose: Unit tests for `Domain`.
    - Depends on: `Domain`.

## Project References

- `Application -> Domain`
- `Infrastructure -> Domain`
- `Agent -> Application`, `Agent -> Infrastructure`
- `Domain.Tests -> Domain`

Rationale: Domain remains framework-agnostic; Application orchestrates domain logic; Infrastructure provides external adapter implementations; Agent composes and hosts.

## Packages and Compatibility

- `Infrastructure`:
  - `Microsoft.Data.SqlClient` for SQL upsert (MERGE) operations and logging.
  - `Polly` for retry/backoff and F5 token-bucket throttling wrappers.
- `Agent`:
  - `Serilog.AspNetCore` + `Serilog.Sinks.File` for console/file logging.
  - `Microsoft.Extensions.Hosting.WindowsServices (9.0.0)` to run as Windows Service on `net9.0` without package downgrades.

Note: We pinned `WindowsServices` to 9.0.0 to keep parity with `Microsoft.Extensions.Hosting (9.x)` and avoid NU1605.

## Folders To Be Added Next

- `src/Domain/Interfaces/` (ports): `ICertificateCollector`, `IMachineInventoryPort`, `IF5Client`, `ISqlWriter`, `ITeamsNotifier`, `IClock`.
- `src/Application/UseCases/`: Orchestrators for weekly digest, certificate collection, F5 inventory, IIS inventory.
- `src/Infrastructure/Adapters/`:
  - `Sql/` for `ISqlWriter` (MERGE upsert, logging writes).
  - `F5/` for `IF5Client` (REST + Polly throttling 5 rps).
  - `WinRM/` for remote OS/IIS commands (10 concurrent sessions cap).
  - `Files/` for CIFS PFX repository access.
  - `Teams/` for weekly digest sender.
- `src/Agent/`:
  - `Composition/` for DI setup and config binding.
  - `Scheduling/` for weekly digest trigger and harvest loops.
  - `appsettings.json` for concurrency limits, F5 rate limits, SQL connection, log paths.

## Config Baselines (to add)

- `Agent/appsettings.json` keys:
  - `Sql:ConnectionString`
  - `F5:BaseUrl`, `F5:Username`, `F5:Partition`, `F5:RequestsPerSecond` (default 5)
  - `WinRM:MaxConcurrency` (default 10)
  - `Inventory:WeeklyDigest:Enabled`, `DayOfWeek`, `HourUtc`
  - `Logging:Path`, `MinimumLevel`

## Operational Constraints Reflected

- Pull-only collectors; no agents on remotes.
- GMSA for identity; no secrets vault initially.
- Weekly Teams digest; prod-only; 30-day window with suppression after first alert.
- Current-state persistence with canonical `Certificates` + `MachineCertificates` association.

## Next Steps

1) Add domain ports/interfaces and initial domain models.
2) Implement `Infrastructure` adapters (SQL writer and F5 client first) with Polly policies.
3) Wire DI and Serilog in `Agent`, add `appsettings.json` with defaults.
4) Create a simple end-to-end “smoke” use case (e.g., read a known set, upsert to SQL, log).
5) Add Pester parity tests later or xUnit for adapters as needed.

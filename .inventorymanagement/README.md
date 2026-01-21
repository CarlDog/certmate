# Cambridge Inventory Management

This repository contains PowerShell scripts for inventory management at Cambridge, including certificate management, machine inventory, and user activity tracking.

## Architecture: Hexagonal (Ports & Adapters) Foundation

This repository implements a **full hexagonal architecture** to support evolution from certificate collection to comprehensive infrastructure management platform.

### Current Structure (7 Projects - All Committed)

```text
src/
├── Domain/              # Pure business logic (zero dependencies)
├── Application/         # Use case orchestration
├── Infrastructure/      # External adapters (SQL, WinRM, F5, Teams)
├── Agent/               # Windows Service host (composition root)
└── InventoryWeb/        # Phase 3 - WebUI (future)
tests/
├── Domain.Tests/        # Pure unit tests
├── Application.Tests/   # Use case tests (mocked ports)
└── Infrastructure.Tests/# Adapter integration tests
docs/architecture/       # ADRs, schema design, implementation roadmap
v1.0/                    # Legacy PowerShell (read-only, failed experiment)
```

### Incremental Population (ADR-002)

The hexagonal scaffold is **complete and committed** but will be **populated incrementally**:

- **Phase 1 (6-8 weeks):** Domain models + Infrastructure (SQL, WinRM) + Agent orchestration
- **Phase 2 (4-6 weeks, starting after Phase 1):** Application use cases + Infrastructure (F5, Repository)
- **Phase 3 (4-6 weeks, starting after Phase 2):** InventoryWeb (WebUI) sharing Domain/Infrastructure layers

**Why full architecture from day 1?**

- This is a **platform, not a script** - Multi-year vision for infrastructure management
- Phase 3 WebUI will share Domain models and Infrastructure adapters
- Additional features planned (scheduled tasks, IIS inventory, services, compliance)
- Scaffold already complete (47 files committed, builds cleanly)

**Guard rails against over-engineering:**

- No `NotImplementedException` in main branch
- Interfaces only when second implementation exists
- Real tests or no test projects
- Document scaffold intent (this README)

See `docs/architecture/architectural-decisions.md` for complete rationale (especially ADR-002).

### Documentation Structure

Documentation is organized into four focused areas:

- **`docs/architecture/`** - Design authority (ADRs, data model design, component architectures)
- **`docs/planning/`** - Execution roadmap (phases, tasks, timelines)
- **`docs/implementation/`** - Developer guides (setup, patterns, troubleshooting)
- **`docs/reference/`** - Legacy executable artifacts; schema DDL now lives in `docs/architecture/schema-ddl.sql`

**Start here:** `docs/README.md` for navigation guide

**Key documents:**

- Architecture overview: `docs/architecture/architecture-overview.md`
- Architectural decisions: `docs/architecture/architectural-decisions.md`
- Implementation roadmap: `docs/planning/implementation-roadmap.md`
- Schema DDL: `docs/architecture/schema-ddl.sql`

### v1.0 Legacy

All PowerShell scripts moved to `v1.0/` as read-only reference. v1.0 was a failed experiment (sporadic, glitchy local agents). v2.0 uses central WinRM orchestrator. Do not modify `v1.0/` except for emergency production hotfixes.

## Logging Architecture

### v2.0: Serilog Structured Logging (Current)

The v2.0 C# Agent uses **Serilog** for structured logging with multiple sinks:

- **Console Sink**: Real-time monitoring during development
- **File Sink**: Rolling log files (`logs/inventory-{Date}.log`)
- **SQL Sink**: Structured events to `InventoryLogs` table

**Configuration** (`src/Agent/appsettings.json`):

```json
{
  "Serilog": {
    "MinimumLevel": "Information",
    "WriteTo": [
      { "Name": "Console" },
      { "Name": "File", "Args": { "path": "logs/inventory-.log", "rollingInterval": "Day" }},
      { "Name": "MSSqlServer", "Args": { "connectionString": "...", "tableName": "InventoryLogs" }}
    ]
  }
}
```

**Structured Properties**: Logs include `MachineName`, `SourceType`, `ThumbprintCount` for rich queries.

See `docs/architecture/architectural-decisions.md` (ADR-006) for rationale.

### v1.0: PowerShell Legacy Logging (Archived)

Legacy PowerShell scripts in `v1.0/` use custom `Write-Log` functions with direct SQL inserts:

**Table Schema** (retained for backward compatibility):

```sql
CREATE TABLE InventoryLogs (
    LogId INT IDENTITY(1,1) PRIMARY KEY,
    Timestamp DATETIME2 NOT NULL,
    ScriptName NVARCHAR(100) NOT NULL,
    Severity NVARCHAR(20) NOT NULL,  -- 'Info', 'Warning', 'Error'
    Message NVARCHAR(MAX) NOT NULL,
    MachineName NVARCHAR(255) NULL,
    AdditionalData NVARCHAR(MAX) NULL
)
```

**Usage Example** (legacy):

```powershell
Write-Log -ScriptName "certsRepo" -Severity "Info" -Message "Starting harvest"
```

**Querying Legacy Logs**:

```sql
-- Get all errors from v1.0 scripts
SELECT * FROM InventoryLogs
WHERE ScriptName IN ('certsRepo', 'machineList', 'f5Inventory')
  AND Severity = 'Error'
ORDER BY Timestamp DESC
```

**Note**: v1.0 scripts are read-only. Do not modify except for emergency production hotfixes.

## Documentation

All documentation is now organized under `docs/` with four focused areas:

- **Architecture** (`docs/architecture/`) - Design decisions, ADRs, data model, component breakdowns
- **Planning** (`docs/planning/`) - Roadmap, phases, tasks, timelines
- **Implementation** (`docs/implementation/`) - Developer guides, setup, patterns (to be created)
- **Reference** (`docs/reference/`) - Legacy artifacts (schema DDL relocated to `docs/architecture/schema-ddl.sql`)

**Quick Links:**

- Start here: `docs/README.md`
- Architecture overview: `docs/architecture/architecture-overview.md`
- All ADRs: `docs/architecture/architectural-decisions.md`
- Roadmap: `docs/planning/implementation-roadmap.md`
- Schema: `docs/architecture/schema-ddl.sql`

## Contact

For questions or issues, contact Carl R. Yeager.

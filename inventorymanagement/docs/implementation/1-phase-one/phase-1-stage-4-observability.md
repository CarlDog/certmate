# Phase 1 Stage 4: Observability (Weeks 3-3.5)

**Last Updated:** November 20, 2025
**Status:** Ready for Implementation
**Owner:** Carl R. Yeager
**Duration:** ~0.5 weeks

---

## Overview

Establish comprehensive observability infrastructure with structured logging, SQL-based log persistence, and operational metrics. This enables effective troubleshooting and monitoring of the harvest service.

**Primary Goal:** Achieve full visibility into harvest operations with structured logs queryable from SQL and real-time metrics.

---

## Scope

**In Scope:**
- Structured logging with Serilog (console + file + SQL sinks)
- SQL logging schema (matching v1.0 InventoryLogs table)
- Contextual logging (harvest cycle ID, machine FQDN, operation type)
- Basic metrics collection (harvest duration, success rate, cert counts)
- Log queries for troubleshooting (recent errors, slow machines, harvest history)
- Log retention policy (90 days)

**Out of Scope:**
- Application Insights / Azure Monitor (Phase 3+)
- Prometheus/Grafana dashboards (Phase 3+)
- Alerting/notifications (Phase 3+)
- Distributed tracing (Phase 3+)

---

## Deliverables

| ID | Deliverable | Location | Acceptance Criteria |
|----|-------------|----------|---------------------|
| D4.1 | SQL logging schema | `src/Infrastructure/Persistence/Schema/003-logging-schema.sql` | InventoryLogs table created |
| D4.2 | Serilog SQL sink | `src/Agent/Program.cs` | Logs written to SQL table |
| D4.3 | Contextual logging | Throughout codebase | All log entries have HarvestCycleId, MachineFQDN |
| D4.4 | Metrics collection | `src/Application/Metrics/HarvestMetrics.cs` | Success rate, duration, cert count tracked |
| D4.5 | Log query scripts | `scripts/Queries/` | Operational queries for troubleshooting |
| D4.6 | Log retention | SQL Agent job or cleanup script | Logs older than 90 days auto-deleted |

---

## Tasks

### Task Group A: SQL Logging Infrastructure

**Duration:** 1 day

#### A1: Create Logging Schema

**File:** `src/Infrastructure/Persistence/Schema/003-logging-schema.sql`

```sql
-- ============================================================================
-- Logging Schema (matching v1.0 InventoryLogs table for compatibility)
-- ============================================================================

USE ProdSpt_Inventory;
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'InventoryLogs')
BEGIN
    CREATE TABLE InventoryLogs (
        Id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        Timestamp DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        Level NVARCHAR(20) NOT NULL,           -- Information, Warning, Error, Fatal
        Message NVARCHAR(MAX) NOT NULL,
        Exception NVARCHAR(MAX) NULL,

        -- Contextual Properties
        HarvestCycleId UNIQUEIDENTIFIER NULL,  -- Correlate all logs within a cycle
        MachineFQDN NVARCHAR(255) NULL,        -- Target machine being processed
        OperationType NVARCHAR(50) NULL,       -- Harvest, Persistence, WinRM, etc.

        -- Additional Serilog Properties (JSON)
        Properties NVARCHAR(MAX) NULL,         -- JSON: {"CertCount":42,"Duration":1.23}

        CONSTRAINT CK_InventoryLogs_Level CHECK (Level IN ('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')),
        CONSTRAINT CK_InventoryLogs_Properties_IsJson CHECK (ISJSON(Properties) = 1 OR Properties IS NULL)
    );

    -- Index for time-based queries
    CREATE NONCLUSTERED INDEX IX_InventoryLogs_Timestamp ON InventoryLogs (Timestamp DESC);

    -- Index for filtering by level
    CREATE NONCLUSTERED INDEX IX_InventoryLogs_Level ON InventoryLogs (Level) INCLUDE (Timestamp, Message);

    -- Index for machine-specific queries
    CREATE NONCLUSTERED INDEX IX_InventoryLogs_MachineFQDN ON InventoryLogs (MachineFQDN) WHERE MachineFQDN IS NOT NULL;

    -- Index for harvest cycle correlation
    CREATE NONCLUSTERED INDEX IX_InventoryLogs_HarvestCycleId ON InventoryLogs (HarvestCycleId) WHERE HarvestCycleId IS NOT NULL;

    PRINT 'Created table: InventoryLogs';
END
GO
```

#### A2: Log Cleanup Procedure

**File:** `src/Infrastructure/Persistence/Schema/004-log-cleanup-procedure.sql`

```sql
-- ============================================================================
-- Log Cleanup - Delete logs older than 90 days
-- Schedule this via SQL Agent Job (daily at 2 AM)
-- ============================================================================

USE ProdSpt_Inventory;
GO

IF OBJECT_ID('dbo.CleanupInventoryLogs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.CleanupInventoryLogs;
GO

CREATE PROCEDURE dbo.CleanupInventoryLogs
    @RetentionDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CutoffDate DATETIMEOFFSET = DATEADD(day, -@RetentionDays, SYSDATETIMEOFFSET());
    DECLARE @DeletedRows INT;

    DELETE FROM InventoryLogs
    WHERE Timestamp < @CutoffDate;

    SET @DeletedRows = @@ROWCOUNT;

    -- Log the cleanup operation
    INSERT INTO InventoryLogs (Level, Message, OperationType, Properties)
    VALUES (
        'Information',
        'Log cleanup completed',
        'LogCleanup',
        JSON_OBJECT('DeletedRows': @DeletedRows, 'RetentionDays': @RetentionDays, 'CutoffDate': CONVERT(NVARCHAR, @CutoffDate, 127))
    );

    PRINT CONCAT('Deleted ', @DeletedRows, ' log entries older than ', @RetentionDays, ' days');
END
GO

PRINT 'Created procedure: dbo.CleanupInventoryLogs';
GO
```

---

### Task Group B: Structured Logging Configuration

**Duration:** 1 day

#### B1: Configure Serilog with SQL Sink

Update `src/Agent/Program.cs`:

```csharp
using Serilog;
using Serilog.Sinks.MSSqlServer;
using System.Collections.ObjectModel;
using System.Data;

// ... existing imports ...

// Configure Serilog with SQL sink
var connectionString = builder.Configuration.GetConnectionString("InventoryDatabase");

Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .Enrich.FromLogContext()
    .Enrich.WithProperty("Application", "CambridgeInventory")
    .Enrich.WithProperty("Environment", builder.Environment.EnvironmentName)
    .WriteTo.Console(
        outputTemplate: "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj} {Properties:j}{NewLine}{Exception}")
    .WriteTo.File(
        path: "logs/inventory-.txt",
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 30,
        outputTemplate: "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} {Level:u3}] [{HarvestCycleId}] [{MachineFQDN}] {Message:lj}{NewLine}{Exception}")
    .WriteTo.MSSqlServer(
        connectionString: connectionString,
        sinkOptions: new MSSqlServerSinkOptions
        {
            TableName = "InventoryLogs",
            SchemaName = "dbo",
            AutoCreateSqlTable = false,  // We created it manually
            BatchPostingLimit = 50,
            BatchPeriod = TimeSpan.FromSeconds(5)
        },
        columnOptions: GetSqlColumnOptions())
    .CreateLogger();

// ... rest of Program.cs ...

static ColumnOptions GetSqlColumnOptions()
{
    var options = new ColumnOptions();

    // Remove default columns we don't need
    options.Store.Remove(StandardColumn.MessageTemplate);

    // Configure standard columns
    options.TimeStamp.ColumnName = "Timestamp";
    options.TimeStamp.DataType = SqlDbType.DateTimeOffset;

    options.Level.ColumnName = "Level";
    options.Level.StoreAsEnum = false;  // Store as string

    options.Message.ColumnName = "Message";
    options.Exception.ColumnName = "Exception";

    options.Properties.ColumnName = "Properties";

    // Add custom columns
    options.AdditionalColumns = new Collection<SqlColumn>
    {
        new SqlColumn
        {
            ColumnName = "HarvestCycleId",
            DataType = SqlDbType.UniqueIdentifier,
            AllowNull = true
        },
        new SqlColumn
        {
            ColumnName = "MachineFQDN",
            DataType = SqlDbType.NVarChar,
            DataLength = 255,
            AllowNull = true
        },
        new SqlColumn
        {
            ColumnName = "OperationType",
            DataType = SqlDbType.NVarChar,
            DataLength = 50,
            AllowNull = true
        }
    };

    return options;
}
```

**NuGet Package Required:**

```xml
<PackageReference Include="Serilog.Sinks.MSSqlServer" Version="6.5.0" />
```

#### B2: Add Contextual Logging to HarvestWorker

Update `src/Agent/Workers/CertificateCollectionWorker.cs`:

```csharp
using Serilog.Context;

// ... existing code ...

private async Task RunHarvestCycleAsync(CancellationToken cancellationToken)
{
    var cycleId = Guid.NewGuid();

    // Push harvest cycle ID to log context (all logs in this scope will include it)
    using (LogContext.PushProperty("HarvestCycleId", cycleId))
    using (LogContext.PushProperty("OperationType", "HarvestCycle"))
    {
        var cycleStart = DateTimeOffset.UtcNow;
        _logger.LogInformation("Starting harvest cycle {CycleId} for {Count} machines", cycleId, _config.TargetMachines.Length);

        var results = new List<HarvestResult>();

        foreach (var machine in _config.TargetMachines)
        {
            // Push machine-specific context
            using (LogContext.PushProperty("MachineFQDN", machine))
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    _logger.LogWarning("Harvest cycle cancelled");
                    break;
                }

                try
                {
                    var result = await _orchestrator.HarvestMachineAsync(machine, cancellationToken);
                    results.Add(result);

                    // Structured logging with metrics
                    if (result.IsSuccess)
                    {
                        _logger.LogInformation(
                            "Harvest successful: {CertCount} certificates, {BindingCount} bindings, {Duration}s",
                            result.CertificatesCollected,
                            result.BindingsCreated,
                            result.Duration.TotalSeconds);
                    }
                    else
                    {
                        _logger.LogWarning("Harvest failed: {Error}", result.ErrorMessage);
                    }
                }
                catch (OperationCanceledException)
                {
                    _logger.LogWarning("Harvest cancelled");
                    break;
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Unexpected error during harvest");
                    results.Add(HarvestResult.Failed(machine, ex.Message));
                }
            }
        }

        // Cycle summary with metrics
        var cycleEnd = DateTimeOffset.UtcNow;
        var cycleDuration = (cycleEnd - cycleStart).TotalSeconds;
        var successCount = results.Count(r => r.IsSuccess);
        var failureCount = results.Count(r => !r.IsSuccess);
        var totalCerts = results.Where(r => r.IsSuccess).Sum(r => r.CertificatesCollected);

        _logger.LogInformation(
            "Harvest cycle {CycleId} complete: {Success} successful, {Failure} failed, {TotalCerts} certificates, {CycleDuration}s",
            cycleId, successCount, failureCount, totalCerts, cycleDuration);
    }
}
```

#### B3: Add Contextual Logging to WinRmOSCollector

Update `src/Infrastructure/CertStores/WinRmOSCollector.cs`:

```csharp
using Serilog.Context;

public async Task<CertificateCollection> CollectAsync(string targetFqdn, CancellationToken cancellationToken)
{
    using (LogContext.PushProperty("MachineFQDN", targetFqdn))
    using (LogContext.PushProperty("OperationType", "WinRM"))
    {
        var startTime = DateTimeOffset.UtcNow;

        try
        {
            _logger.LogInformation("Starting OS certificate collection");

            // ... existing collection logic ...

            var duration = (DateTimeOffset.UtcNow - startTime).TotalSeconds;
            _logger.LogInformation(
                "Collected {CertCount} certificates from {StoreCount} stores in {Duration}s",
                certificates.Count, StorePaths.Length, duration);

            return new CertificateCollection { /* ... */ };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to collect certificates");
            return new CertificateCollection { /* ... */ };
        }
    }
}
```

---

### Task Group C: Metrics Collection

**Duration:** 0.5 days

#### C1: Harvest Metrics Tracker

**File:** `src/Application/Metrics/HarvestMetrics.cs`

```csharp
namespace InventoryManagement.Application.Metrics;

/// <summary>
/// Tracks metrics for harvest operations.
/// Phase 1: In-memory summary. Phase 3: Export to Prometheus/AppInsights.
/// </summary>
public sealed class HarvestMetrics
{
    private long _totalHarvests;
    private long _successfulHarvests;
    private long _failedHarvests;
    private long _totalCertificatesCollected;
    private readonly object _lock = new();

    public void RecordHarvest(bool success, int certificateCount, TimeSpan duration)
    {
        lock (_lock)
        {
            _totalHarvests++;

            if (success)
            {
                _successfulHarvests++;
                _totalCertificatesCollected += certificateCount;
            }
            else
            {
                _failedHarvests++;
            }
        }
    }

    public HarvestMetricsSummary GetSummary()
    {
        lock (_lock)
        {
            return new HarvestMetricsSummary
            {
                TotalHarvests = _totalHarvests,
                SuccessfulHarvests = _successfulHarvests,
                FailedHarvests = _failedHarvests,
                SuccessRate = _totalHarvests > 0 ? (double)_successfulHarvests / _totalHarvests : 0,
                TotalCertificatesCollected = _totalCertificatesCollected
            };
        }
    }
}

public sealed class HarvestMetricsSummary
{
    public long TotalHarvests { get; init; }
    public long SuccessfulHarvests { get; init; }
    public long FailedHarvests { get; init; }
    public double SuccessRate { get; init; }
    public long TotalCertificatesCollected { get; init; }
}
```

Wire into DI in `Program.cs`:

```csharp
builder.Services.AddSingleton<HarvestMetrics>();
```

Update `CertificateCollectionWorker` to record metrics:

```csharp
private readonly HarvestMetrics _metrics;

public CertificateCollectionWorker(
    CollectionOrchestrator orchestrator,
    IOptions<HarvestConfiguration> config,
    HarvestMetrics metrics,  // Add this
    ILogger<CertificateCollectionWorker> logger)
{
    _orchestrator = orchestrator;
    _config = config.Value;
    _metrics = metrics;
    _logger = logger;
}

// In RunHarvestCycleAsync:
foreach (var result in results)
{
    _metrics.RecordHarvest(result.IsSuccess, result.CertificatesCollected, result.Duration);
}

// Log metrics summary periodically
var summary = _metrics.GetSummary();
_logger.LogInformation(
    "Metrics summary: {TotalHarvests} total, {SuccessRate:P1} success rate, {TotalCerts} certificates",
    summary.TotalHarvests, summary.SuccessRate, summary.TotalCertificatesCollected);
```

---

### Task Group D: Operational Queries

**Duration:** 0.5 days

#### D1: Troubleshooting Query Scripts

**File:** `scripts/Queries/RecentErrors.sql`

```sql
-- Recent errors (last 24 hours)
USE ProdSpt_Inventory;

SELECT TOP 100
    Timestamp,
    MachineFQDN,
    OperationType,
    Message,
    Exception
FROM InventoryLogs
WHERE Level IN ('Error', 'Fatal')
  AND Timestamp >= DATEADD(hour, -24, SYSDATETIMEOFFSET())
ORDER BY Timestamp DESC;
```

**File:** `scripts/Queries/HarvestCycleDetails.sql`

```sql
-- Details for a specific harvest cycle
USE ProdSpt_Inventory;

DECLARE @CycleId UNIQUEIDENTIFIER = '<PASTE_CYCLE_ID_HERE>';

SELECT
    Timestamp,
    Level,
    MachineFQDN,
    OperationType,
    Message,
    Exception
FROM InventoryLogs
WHERE HarvestCycleId = @CycleId
ORDER BY Timestamp;
```

**File:** `scripts/Queries/SlowMachines.sql`

```sql
-- Machines with harvest duration > 60 seconds (last 7 days)
USE ProdSpt_Inventory;

SELECT
    MachineFQDN,
    COUNT(*) AS HarvestCount,
    AVG(CAST(JSON_VALUE(Properties, '$.Duration') AS FLOAT)) AS AvgDurationSeconds,
    MAX(CAST(JSON_VALUE(Properties, '$.Duration') AS FLOAT)) AS MaxDurationSeconds
FROM InventoryLogs
WHERE OperationType = 'Harvest'
  AND Level = 'Information'
  AND Timestamp >= DATEADD(day, -7, SYSDATETIMEOFFSET())
  AND JSON_VALUE(Properties, '$.Duration') IS NOT NULL
GROUP BY MachineFQDN
HAVING AVG(CAST(JSON_VALUE(Properties, '$.Duration') AS FLOAT)) > 60
ORDER BY AvgDurationSeconds DESC;
```

**File:** `scripts/Queries/HarvestHistory.sql`

```sql
-- Harvest history for a specific machine (last 30 days)
USE ProdSpt_Inventory;

DECLARE @Machine NVARCHAR(255) = 'server01.corp.cambridge.edu';

SELECT
    Timestamp,
    Level,
    Message,
    JSON_VALUE(Properties, '$.CertCount') AS CertificateCount,
    JSON_VALUE(Properties, '$.Duration') AS DurationSeconds
FROM InventoryLogs
WHERE MachineFQDN = @Machine
  AND OperationType IN ('Harvest', 'WinRM')
  AND Timestamp >= DATEADD(day, -30, SYSDATETIMEOFFSET())
ORDER BY Timestamp DESC;
```

---

## Acceptance Criteria

| ID | Criteria | Validation Method |
|----|----------|-------------------|
| AC1 | Logs written to SQL | Run harvest, query InventoryLogs table, verify rows exist |
| AC2 | Contextual properties present | Verify HarvestCycleId, MachineFQDN populated in logs |
| AC3 | Structured properties in JSON | Verify CertCount, Duration in Properties column |
| AC4 | Log retention works | Run cleanup procedure, verify old logs deleted |
| AC5 | Console logging readable | Review console output during harvest |
| AC6 | File logging rotating | Verify daily log files created in logs/ directory |
| AC7 | Query scripts return results | Run each operational query, verify results |

---

## Dependencies

**Required Before Starting:**
- Stage 3 complete (Worker, orchestrator, harvest cycle)
- SQL Server with InventoryLogs schema deployed
- Serilog NuGet packages installed

**Provides to Next Stage:**
- Comprehensive logging for troubleshooting
- Metrics baseline for performance validation
- Operational visibility for production deployment

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| SQL sink performance issues | Medium | Batch writing (50 logs/5 seconds), async sink |
| Log table growth | Low | 90-day retention policy with automated cleanup |
| Missing context in logs | Medium | Code review to ensure LogContext used consistently |

---

## Success Metrics

- **Log completeness:** 100% of harvests have corresponding logs in SQL
- **Context coverage:** ≥95% of logs have HarvestCycleId and MachineFQDN
- **Query performance:** Operational queries return <5 seconds
- **Log retention:** Automated cleanup runs daily, maintains 90-day window

---

## Next Stage

**Stage 5: Hardening (Weeks 3.5-4)** - End-to-end testing, documentation, deployment preparation, and production readiness validation.

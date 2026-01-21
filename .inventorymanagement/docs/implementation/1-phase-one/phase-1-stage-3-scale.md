# Phase 1 Stage 3: Scale (Weeks 2.5-3)

**Last Updated:** November 20, 2025
**Status:** Ready for Implementation
**Owner:** Carl R. Yeager
**Duration:** ~0.5 weeks

---

## Overview

Scale from single-machine harvest to sequential multi-machine harvesting with robust error handling and operational resilience. This stage does NOT implement parallelization (Phase 2), but ensures reliable sequential processing of 5-10 target machines.

**Primary Goal:** Reliably harvest certificates from 5-10 machines sequentially with comprehensive error handling and graceful degradation.

---

## Scope

**In Scope:**
- Sequential multi-machine orchestration (Worker loop)
- Error handling (WinRM failures, SQL exceptions, timeout handling)
- Basic retry logic (fixed retry, no exponential backoff yet)
- Machine status tracking (Reachable/Unreachable)
- Connection lifecycle management
- Configuration-driven target machine list (appsettings.json)
- Graceful shutdown handling

**Out of Scope:**
- Parallel/concurrent execution (Phase 2)
- Polly retry policies (Phase 2)
- SQLite buffering (Phase 2)
- Advanced telemetry (Stage 4)
- Production deployment (Stage 5)

---

## Deliverables

| ID | Deliverable | Location | Acceptance Criteria |
|----|-------------|----------|---------------------|
| D3.1 | Harvest Worker | `src/Agent/Workers/CertificateCollectionWorker.cs` | Sequential harvest of 5-10 machines completes |
| D3.2 | Collection orchestrator | `src/Application/Collection/CollectionOrchestrator.cs` | Coordinates collection + persistence |
| D3.3 | Error handling | Throughout Infrastructure | Failed machines don't block others |
| D3.4 | Configuration | `src/Agent/appsettings.json` | Target machines, intervals, timeouts |
| D3.5 | DI composition | `src/Agent/Program.cs` | All services wired correctly |
| D3.6 | Connection management | `src/Infrastructure/CertStores/WinRmConnectionPool.cs` | Runspaces closed cleanly |

---

## Tasks

### Task Group A: Application Layer Orchestration

**Duration:** 1 day

#### A1: Implement CollectionOrchestrator

**File:** `src/Application/Collection/CollectionOrchestrator.cs`

```csharp
namespace InventoryManagement.Application.Collection;

using Microsoft.Extensions.Logging;
using InventoryManagement.Domain.Ports;
using InventoryManagement.Domain.Machines;

/// <summary>
/// Orchestrates certificate harvest workflow:
/// 1. Collect certs from remote machine (ICertificateStoreReader)
/// 2. Persist to SQL (IIngestionWriter)
/// 3. Update machine status
///
/// Phase 1: Sequential only. Phase 2: Parallel with SemaphoreSlim.
/// </summary>
public sealed class CollectionOrchestrator
{
    private readonly ICertificateStoreReader _certificateReader;
    private readonly IIngestionWriter _ingestionWriter;
    private readonly ILogger<CollectionOrchestrator> _logger;

    public CollectionOrchestrator(
        ICertificateStoreReader certificateReader,
        IIngestionWriter ingestionWriter,
        ILogger<CollectionOrchestrator> logger)
    {
        _certificateReader = certificateReader;
        _ingestionWriter = ingestionWriter;
        _logger = logger;
    }

    /// <summary>
    /// Harvests certificates from a single target machine.
    /// </summary>
    public async Task<HarvestResult> HarvestMachineAsync(string fqdn, CancellationToken cancellationToken)
    {
        var startTime = DateTimeOffset.UtcNow;
        _logger.LogInformation("Starting harvest for {Machine}", fqdn);

        try
        {
            // Step 1: Collect certificates
            var collection = await _certificateReader.CollectAsync(fqdn, cancellationToken);

            if (!collection.IsSuccess)
            {
                _logger.LogWarning(
                    "Collection failed for {Machine}: {Error}",
                    fqdn, collection.ErrorMessage);

                return HarvestResult.Failed(fqdn, collection.ErrorMessage ?? "Unknown collection error");
            }

            // Step 2: Build Machine entity
            var machine = new Machine
            {
                Hostname = ExtractHostname(fqdn),
                FQDN = fqdn,
                Environment = Machine.DetermineEnvironment(fqdn),
                FirstSeen = startTime,
                LastSeen = startTime,
                WinRMStatus = "Reachable"
            };

            // Step 3: Persist
            var outcome = await _ingestionWriter.PersistHarvestAsync(
                machine, collection.Certificates, collection.Locations, cancellationToken);

            if (!outcome.IsSuccess)
            {
                _logger.LogError(
                    "Persistence failed for {Machine}: {Error}",
                    fqdn, outcome.ErrorMessage);

                return HarvestResult.Failed(fqdn, outcome.ErrorMessage ?? "Unknown persistence error");
            }

            var duration = DateTimeOffset.UtcNow - startTime;
            _logger.LogInformation(
                "Completed harvest for {Machine}: {CertCount} certs, {BindingCount} bindings in {Duration}s",
                fqdn, outcome.CertificatesUpserted, outcome.BindingsUpserted, duration.TotalSeconds);

            return HarvestResult.Success(
                fqdn, outcome.CertificatesUpserted, outcome.BindingsUpserted, duration);
        }
        catch (OperationCanceledException)
        {
            _logger.LogWarning("Harvest cancelled for {Machine}", fqdn);
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unexpected error harvesting {Machine}", fqdn);
            return HarvestResult.Failed(fqdn, ex.Message);
        }
    }

    private string? ExtractHostname(string fqdn)
    {
        // Extract hostname before first dot: server01.corp.cambridge.edu -> server01
        var firstDot = fqdn.IndexOf('.');
        return firstDot > 0 ? fqdn.Substring(0, firstDot).ToUpperInvariant() : null;
    }
}

/// <summary>
/// Result of a single machine harvest operation.
/// </summary>
public sealed class HarvestResult
{
    public required string MachineFQDN { get; init; }
    public required bool IsSuccess { get; init; }
    public int CertificatesCollected { get; init; }
    public int BindingsCreated { get; init; }
    public TimeSpan Duration { get; init; }
    public string? ErrorMessage { get; init; }

    public static HarvestResult Success(string fqdn, int certCount, int bindingCount, TimeSpan duration) =>
        new()
        {
            MachineFQDN = fqdn,
            IsSuccess = true,
            CertificatesCollected = certCount,
            BindingsCreated = bindingCount,
            Duration = duration
        };

    public static HarvestResult Failed(string fqdn, string errorMessage) =>
        new()
        {
            MachineFQDN = fqdn,
            IsSuccess = false,
            ErrorMessage = errorMessage
        };
}
```

---

### Task Group B: Agent Worker

**Duration:** 1 day

#### B1: Implement CertificateCollectionWorker

**File:** `src/Agent/Workers/CertificateCollectionWorker.cs`

```csharp
namespace InventoryManagement.Agent.Workers;

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using InventoryManagement.Application.Orchestrators;

/// <summary>
/// Background service that runs scheduled certificate harvests.
/// Phase 1: Sequential execution. Phase 2: Parallel with throttling.
/// </summary>
public sealed class CertificateCollectionWorker : BackgroundService
{
    private readonly CollectionOrchestrator _orchestrator;
    private readonly ILogger<CertificateCollectionWorker> _logger;
    private readonly HarvestConfiguration _config;

    public CertificateCollectionWorker(
        CollectionOrchestrator orchestrator,
        IOptions<HarvestConfiguration> config,
        ILogger<CertificateCollectionWorker> logger)
    {
        _orchestrator = orchestrator;
        _config = config.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation(
            "Certificate Collection Worker started. Interval: {Interval} minutes, Target machines: {Count}",
            _config.IntervalMinutes, _config.TargetMachines.Length);

        // Run immediately on startup
        await RunHarvestCycleAsync(stoppingToken);

        // Then run on schedule
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(_config.IntervalMinutes));

        while (!stoppingToken.IsCancellationRequested && await timer.WaitForNextTickAsync(stoppingToken))
        {
            await RunHarvestCycleAsync(stoppingToken);
        }

        _logger.LogInformation("Certificate Collection Worker stopped");
    }

    private async Task RunHarvestCycleAsync(CancellationToken cancellationToken)
    {
        var cycleStart = DateTimeOffset.UtcNow;
        _logger.LogInformation("Starting collection cycle for {Count} machines", _config.TargetMachines.Length);

        var results = new List<HarvestResult>();

        // SEQUENTIAL EXECUTION (Phase 1)
        // Phase 2 will replace this with parallel execution + SemaphoreSlim throttling
        foreach (var machine in _config.TargetMachines)
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
            }
            catch (OperationCanceledException)
            {
                _logger.LogWarning("Harvest cancelled for {Machine}", machine);
                break;
            }
            catch (Exception ex)
            {
                // Isolated exception handling - one machine failure doesn't stop others
                _logger.LogError(ex, "Unexpected error processing {Machine}", machine);
                results.Add(HarvestResult.Failed(machine, ex.Message));
            }
        }

        // Summary logging
        var cycleEnd = DateTimeOffset.UtcNow;
        var successCount = results.Count(r => r.IsSuccess);
        var failureCount = results.Count(r => !r.IsSuccess);
        var totalCerts = results.Where(r => r.IsSuccess).Sum(r => r.CertificatesCollected);

        _logger.LogInformation(
            "Harvest cycle complete: {Success} successful, {Failure} failed, {TotalCerts} certificates in {Duration}s",
            successCount, failureCount, totalCerts, (cycleEnd - cycleStart).TotalSeconds);

        if (failureCount > 0)
        {
            var failedMachines = results.Where(r => !r.IsSuccess).Select(r => r.MachineFQDN);
            _logger.LogWarning("Failed machines: {Machines}", string.Join(", ", failedMachines));
        }
    }
}
```

#### B2: Harvest Configuration

**File:** `src/Agent/Configuration/HarvestConfiguration.cs`

```csharp
namespace InventoryManagement.Agent.Configuration;

/// <summary>
/// Configuration for certificate harvest operations.
/// Bound from appsettings.json "Harvest" section.
/// </summary>
public sealed class HarvestConfiguration
{
    public required string[] TargetMachines { get; init; }
    public int IntervalMinutes { get; init; } = 60;  // Default: hourly
    public int TimeoutSeconds { get; init; } = 120;  // Default: 2 minutes per machine
    public int MaxRetries { get; init; } = 2;        // Default: retry twice on failure
}
```

#### B3: appsettings.json

**File:** `src/Agent/appsettings.json`

```json
{
  "Harvest": {
    "TargetMachines": [
      "server01.corp.cambridge.edu",
      "server02.corp.cambridge.edu",
      "server03.corp.cambridge.edu",
      "server04.corp.cambridge.edu",
      "server05.corp.cambridge.edu"
    ],
    "IntervalMinutes": 60,
    "TimeoutSeconds": 120,
    "MaxRetries": 2
  },
  "ConnectionStrings": {
    "InventoryDatabase": "Server=localhost;Database=ProdSpt_Inventory;Integrated Security=true;TrustServerCertificate=true;"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning",
      "Microsoft.Hosting.Lifetime": "Information"
    }
  }
}
```

---

### Task Group C: DI Composition

**Duration:** 0.5 days

#### C1: Wire Dependencies in Program.cs

**File:** `src/Agent/Program.cs`

```csharp
using InventoryManagement.Agent.Workers;
using InventoryManagement.Agent.Configuration;
using InventoryManagement.Application.Orchestrators;
using InventoryManagement.Domain.Ports;
using InventoryManagement.Infrastructure.CertStores;
using InventoryManagement.Infrastructure.Persistence;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Serilog;

// Configure Serilog
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .WriteTo.Console()
    .WriteTo.File("logs/inventory-.txt", rollingInterval: RollingInterval.Day)
    .CreateLogger();

try
{
    Log.Information("Starting Cambridge Certificate Inventory Management Service");

    var builder = Host.CreateApplicationBuilder(args);

    // Configuration
    builder.Services.Configure<HarvestConfiguration>(
        builder.Configuration.GetSection("Harvest"));

    // Logging
    builder.Services.AddSerilog();

    // Domain Services (stateless, can be singleton)
    builder.Services.AddSingleton<CertificateMapper>();

    // Application Layer
    builder.Services.AddScoped<CollectionOrchestrator>();

    // Infrastructure Layer - Certificate Collection
    builder.Services.AddScoped<ICertificateStoreReader, WinRmOSCollector>();

    // Infrastructure Layer - Persistence
    builder.Services.AddScoped<IIngestionWriter, SqlServerPersistence>();

    // Background Worker
    builder.Services.AddHostedService<CertificateCollectionWorker>();

    var host = builder.Build();
    await host.RunAsync();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Application terminated unexpectedly");
    return 1;
}
finally
{
    await Log.CloseAndFlushAsync();
}

return 0;
```

**NuGet Packages Required:**

Add to `src/Agent/Agent.csproj`:

```xml
<ItemGroup>
  <PackageReference Include="Serilog.Extensions.Hosting" Version="8.0.0" />
  <PackageReference Include="Serilog.Sinks.Console" Version="5.0.1" />
  <PackageReference Include="Serilog.Sinks.File" Version="5.0.0" />
  <PackageReference Include="Microsoft.Extensions.Hosting" Version="8.0.0" />
  <PackageReference Include="Microsoft.Extensions.Configuration.Json" Version="8.0.0" />
</ItemGroup>

<ItemGroup>
  <ProjectReference Include="..\Application\Application.csproj" />
  <ProjectReference Include="..\Infrastructure\Infrastructure.csproj" />
</ItemGroup>
```

---

### Task Group D: Connection Management

**Duration:** 0.5 days

#### D1: Enhance WinRmOSCollector with Timeout Handling

Update `src/Infrastructure/CertStores/WinRmOSCollector.cs` to add timeout and retry:

```csharp
// Add to WinRmOSCollector class:

private readonly int _timeoutSeconds;
private readonly int _maxRetries;

public WinRmOSCollector(
    ILogger<WinRmOSCollector> logger,
    CertificateMapper mapper,
    IOptions<HarvestConfiguration> config)
{
    _logger = logger;
    _mapper = mapper;
    _timeoutSeconds = config.Value.TimeoutSeconds;
    _maxRetries = config.Value.MaxRetries;
}

public async Task<CertificateCollection> CollectAsync(string targetFqdn, CancellationToken cancellationToken)
{
    var attempt = 0;
    Exception? lastException = null;

    while (attempt < _maxRetries)
    {
        attempt++;

        try
        {
            return await CollectWithTimeoutAsync(targetFqdn, cancellationToken);
        }
        catch (Exception ex) when (attempt < _maxRetries && IsRetriableError(ex))
        {
            lastException = ex;
            _logger.LogWarning(
                "Attempt {Attempt}/{MaxRetries} failed for {Machine}: {Error}",
                attempt, _maxRetries, targetFqdn, ex.Message);

            // Simple fixed delay between retries (Phase 2 will use Polly exponential backoff)
            await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
        }
    }

    _logger.LogError(lastException, "All retry attempts exhausted for {Machine}", targetFqdn);

    return new CertificateCollection
    {
        TargetIdentifier = targetFqdn,
        Certificates = Array.Empty<Certificate>(),
        Locations = Array.Empty<MachineCertificateLocation>(),
        CollectionTimestamp = DateTimeOffset.UtcNow,
        IsSuccess = false,
        ErrorMessage = $"Failed after {_maxRetries} attempts: {lastException?.Message}"
    };
}

private async Task<CertificateCollection> CollectWithTimeoutAsync(
    string targetFqdn, CancellationToken cancellationToken)
{
    using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(_timeoutSeconds));
    using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

    // Original collection logic here with linkedCts.Token
    // (existing CollectAsync implementation)
}

private bool IsRetriableError(Exception ex)
{
    // Retry on network/WinRM errors, not on authentication or permission errors
    return ex is System.Net.Sockets.SocketException
        || ex is TimeoutException
        || ex is PSRemotingTransportException;
}
```

---

## Acceptance Criteria

| ID | Criteria | Validation Method |
|----|----------|-------------------|
| AC1 | Sequential harvest of 5-10 machines | Worker completes cycle successfully |
| AC2 | Failed machine doesn't block others | Inject failure for 1 machine, verify others complete |
| AC3 | Timeout handling works | Set timeout to 5 seconds, verify long-running harvest cancelled |
| AC4 | Retry logic works | Disconnect network mid-harvest, verify retry attempts |
| AC5 | Configuration binding | Modify appsettings.json, verify settings applied |
| AC6 | Graceful shutdown | Send SIGTERM, verify in-progress harvest completes or cancels cleanly |
| AC7 | Summary logging | Verify cycle summary shows success/failure counts |

---

## Dependencies

**Required Before Starting:**
- Stage 2 complete (WinRM collector, persistence layer)
- Test machines (5-10) with WinRM enabled
- Application and Agent projects exist

**Provides to Next Stage:**
- Working multi-machine harvest orchestration
- Error handling baseline for observability
- Configuration structure for production deployment

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Sequential harvest too slow for 300 servers | High | Phase 2 implements parallelization |
| Retry logic causes cascade delays | Medium | Fixed retry delay (5s), max 2 retries |
| Memory leak from unclosed runspaces | Medium | Explicit `using` statements for runspace disposal |

---

## Success Metrics

- **Harvest cycle time:** 5 machines in <5 minutes (avg 1 min/machine)
- **Failure isolation:** 1 failed machine → 4 successful harvests complete
- **Retry effectiveness:** ≥50% of retriable failures succeed on retry
- **Zero worker crashes** due to unhandled exceptions

---

## Next Stage

**Stage 4: Observability (Weeks 3-3.5)** - Implement structured logging with Serilog SQL sink, metrics, and operational dashboards.

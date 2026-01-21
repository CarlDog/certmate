namespace Application.Collection;

using Domain.Interfaces;
using Domain.Machines;
using Microsoft.Extensions.Logging;

/// <summary>
/// Application-layer orchestrator for coordinating certificate collection from multiple sources.
/// Manages orchestration of ICertificateStoreReader implementations with error isolation and logging.
/// Per ADR-002 (Hexagonal Architecture), this layer contains orchestration logic only—not business rules.
/// </summary>
public sealed class CollectionOrchestrator
{
    private readonly ICertificateStoreReader[] _collectors;
    private readonly IIngestionWriter _ingestionWriter;
    private readonly ILogger<CollectionOrchestrator> _logger;

    public CollectionOrchestrator(
        IEnumerable<ICertificateStoreReader> collectors,
        IIngestionWriter ingestionWriter,
        ILogger<CollectionOrchestrator> logger)
    {
        ArgumentNullException.ThrowIfNull(collectors);
        ArgumentNullException.ThrowIfNull(ingestionWriter);
        ArgumentNullException.ThrowIfNull(logger);

        _collectors = collectors.ToArray();
        _ingestionWriter = ingestionWriter;
        _logger = logger;
    }

    /// <summary>
    /// Orchestrates certificate collection and persistence for a target machine.
    /// Isolates collector errors so failure in one source doesn't block others.
    /// </summary>
    /// <param name="machine">Target machine to harvest certificates from</param>
    /// <param name="ct">Cancellation token</param>
    /// <returns>Aggregated result with success/failure metadata</returns>
    public async Task<CollectionResult> CollectAndPersistAsync(Machine machine, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(machine);
        ct.ThrowIfCancellationRequested();

        var cycleId = Guid.NewGuid();
        var errors = new List<string>();
        var totalCertificates = 0;
        var totalBindings = 0;

        if (_logger.IsEnabled(LogLevel.Information))
        {
            _logger.LogInformation(
                "Starting collection for machine {Machine} (CycleId={CycleId}) with {CollectorCount} collectors",
                machine.Hostname,
                cycleId,
                _collectors.Length);
        }

        // Collect from all sources, isolating errors per collector
        var allCertificates = new List<Domain.Certificates.Certificate>();
        var allBindingMetadata = new List<CertificateBinding>();

        foreach (var collector in _collectors)
        {
            try
            {
                var result = await collector.CollectAsync(machine.Hostname, ct).ConfigureAwait(false);

                if (result.IsSuccess)
                {
                    allCertificates.AddRange(result.Certificates);
                    allBindingMetadata.AddRange(result.Bindings);

                    if (_logger.IsEnabled(LogLevel.Debug))
                    {
                        _logger.LogDebug(
                            "Collector {Collector} for {Machine}: {CertCount} certs, {BindingCount} bindings",
                            collector.GetType().Name,
                            machine.Hostname,
                            result.Certificates.Count,
                            result.Bindings.Count);
                    }
                }
                else
                {
                    var errorMsg = $"Collector {collector.GetType().Name} failed: {result.ErrorMessage}";
                    errors.Add(errorMsg);
                    _logger.LogWarning("Collection error for {Machine}: {Error}", machine.Hostname, errorMsg);
                }
            }
            catch (OperationCanceledException)
            {
                throw; // Propagate cancellation
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                var errorMsg = $"Collector {collector.GetType().Name} exception: {ex.Message}";
                errors.Add(errorMsg);
                _logger.LogError(ex, "Unhandled exception in collector {Collector} for {Machine}",
                    collector.GetType().Name, machine.Hostname);
            }
        }

        // Convert binding metadata to MachineCertificate objects
        // Note: MachineId will be set by persistence layer after machine upsert
        var allBindings = ConvertBindingMetadata(allBindingMetadata, machine, out var bindingErrors);
        errors.AddRange(bindingErrors);

        // Persist aggregated results
        try
        {
            var persistenceOutcome = await _ingestionWriter.PersistAsync(
                machine,
                allCertificates,
                allBindings,
                ct).ConfigureAwait(false);

            totalCertificates = persistenceOutcome.CertificatesInserted + persistenceOutcome.CertificatesUpdated;
            totalBindings = persistenceOutcome.BindingsInserted + persistenceOutcome.BindingsUpdated;

            if (!persistenceOutcome.IsSuccess)
            {
                errors.AddRange(persistenceOutcome.Errors);
                _logger.LogWarning(
                    "Persistence reported errors for {Machine}: {ErrorCount} issues",
                    machine.Hostname,
                    persistenceOutcome.Errors.Count);
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            errors.Add($"Persistence exception: {ex.Message}");
            _logger.LogError(ex, "Persistence failed for {Machine}", machine.Hostname);
        }

        var isSuccess = errors.Count == 0;

        if (_logger.IsEnabled(LogLevel.Information))
        {
            _logger.LogInformation(
                "Collection cycle {CycleId} for {Machine} completed: Success={Success}, Certs={CertCount}, Bindings={BindingCount}, Errors={ErrorCount}",
                cycleId,
                machine.Hostname,
                isSuccess,
                totalCertificates,
                totalBindings,
                errors.Count);
        }

        return new CollectionResult
        {
            CycleId = cycleId,
            Machine = machine,
            CertificatesProcessed = totalCertificates,
            BindingsProcessed = totalBindings,
            IsSuccess = isSuccess,
            Errors = errors
        };
    }

    /// <summary>
    /// Converts intermediate binding metadata to MachineCertificate domain objects.
    /// Since MachineId isn't available until after persistence, we use a placeholder (0).
    /// The persistence layer will reconstruct these with the real MachineId after machine upsert.
    /// </summary>
    private List<MachineCertificate> ConvertBindingMetadata(
        List<CertificateBinding> bindingMetadata,
        Machine machine,
        out List<string> errors)
    {
        errors = new List<string>();
        var bindings = new List<MachineCertificate>();
        var now = DateTimeOffset.UtcNow;

        foreach (var binding in bindingMetadata)
        {
            try
            {
                // Create MachineCertificate with placeholder MachineId (0)
                // Persistence layer will re-create these with actual MachineId after machine upsert
                var machineCert = MachineCertificate.Create(
                    machineId: 1, // Temporary; will be replaced during persistence
                    thumbprint: binding.Thumbprint,
                    sourceType: binding.SourceType,
                    pathLocation: binding.PathLocation,
                    bindingContextJson: binding.BindingContext,
                    when: now);

                bindings.Add(machineCert);
            }
            catch (ArgumentException ex)
            {
                _logger.LogWarning(
                    ex,
                    "Invalid binding metadata for {Thumbprint} on {Machine}",
                    binding.Thumbprint,
                    machine.Hostname);
                errors.Add($"Binding validation error: {ex.Message}");
            }
        }

        return bindings;
    }
}

/// <summary>
/// Result of a collection cycle for a single machine.
/// </summary>
public sealed class CollectionResult
{
    public required Guid CycleId { get; init; }
    public required Machine Machine { get; init; }
    public int CertificatesProcessed { get; init; }
    public int BindingsProcessed { get; init; }
    public bool IsSuccess { get; init; }
    public required IReadOnlyCollection<string> Errors { get; init; } = Array.Empty<string>();
}

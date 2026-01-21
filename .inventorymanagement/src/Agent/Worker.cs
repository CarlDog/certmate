namespace Agent;

using System.Collections.Generic;
using System.Linq;
using Configuration;
using Domain.Interfaces;
using Microsoft.Extensions.Options;

internal sealed class Worker : BackgroundService
{
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromMinutes(1);
    private readonly ILogger<Worker> _logger;
    private readonly ICertificateStoreReader[] _collectors;
    private readonly IIngestionWriter _ingestionWriter;
    private readonly TargetServerOptions _targetServers;
    private bool _configurationLogged;

    public Worker(
        ILogger<Worker> logger,
        IEnumerable<ICertificateStoreReader> collectors,
        IIngestionWriter ingestionWriter,
        IOptions<TargetServerOptions> targetServers)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        ArgumentNullException.ThrowIfNull(collectors);
        ArgumentNullException.ThrowIfNull(ingestionWriter);
        ArgumentNullException.ThrowIfNull(targetServers);

        _collectors = collectors.ToArray();
        _ingestionWriter = ingestionWriter;
        _targetServers = targetServers.Value;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            LogConfiguredDependencies();

            using var scope = _logger.BeginScope(new Dictionary<string, object>
            {
                ["Machine"] = Environment.MachineName,
                ["HarvestCycleId"] = Guid.Empty,
                ["CertificateCount"] = 0
            });

            if (_logger.IsEnabled(LogLevel.Information))
            {
                _logger.LogInformation("Inventory agent heartbeat at {Timestamp}", DateTimeOffset.UtcNow);
            }

            await Task.Delay(HeartbeatInterval, stoppingToken).ConfigureAwait(false);
        }
    }

    private void LogConfiguredDependencies()
    {
        if (_configurationLogged)
        {
            return;
        }

        var collectorNames = _collectors.Length == 0
            ? "(none)"
            : string.Join(", ", _collectors.Select(c => c.GetType().Name));

        var targetServerNames = _targetServers.Servers.Count == 0
            ? "(none)"
            : string.Join(", ", _targetServers.Servers);

        _logger.LogInformation(
            "Configured collectors: {Collectors}; Ingestion writer: {Writer}; Target servers: {Servers}",
            collectorNames,
            _ingestionWriter.GetType().Name,
            targetServerNames);

        _configurationLogged = true;
    }
}

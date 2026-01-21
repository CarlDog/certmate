namespace Infrastructure.Persistence;

using System.Text.Json;
using Domain.Certificates;
using Domain.Interfaces;
using Domain.Machines;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

/// <summary>
/// SQL Server adapter for certificate and machine persistence.
/// Uses parameterized MERGE for upserts.
/// </summary>
public sealed class SqlServerPersistence : IIngestionWriter
{
    private readonly string _connectionString;
    private readonly string _connectionDescriptor;
    private readonly TimeSpan _commandTimeout;
    private readonly bool _enableRetryOnFailure;
    private readonly int _maxRetryCount;
    private readonly TimeSpan _maxRetryDelay;
    private readonly ILogger<SqlServerPersistence> _logger;

    public SqlServerPersistence(
        string connectionString,
        TimeSpan commandTimeout,
        bool enableRetryOnFailure,
        int maxRetryCount,
        TimeSpan maxRetryDelay,
        ILogger<SqlServerPersistence> logger)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new ArgumentException("Connection string must be provided.", nameof(connectionString));
        }

        ArgumentOutOfRangeException.ThrowIfNegative(maxRetryCount);

        _connectionString = connectionString;
        _connectionDescriptor = DescribeConnection(connectionString);
        _commandTimeout = commandTimeout;
        _enableRetryOnFailure = enableRetryOnFailure;
        _maxRetryCount = maxRetryCount;
        _maxRetryDelay = maxRetryDelay;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<IngestionOutcome> PersistAsync(
        Machine machine,
        IEnumerable<Certificate> certificates,
        IEnumerable<MachineCertificate> bindings,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(machine);
        ArgumentNullException.ThrowIfNull(certificates);
        ArgumentNullException.ThrowIfNull(bindings);

        ct.ThrowIfCancellationRequested();

        if (_logger.IsEnabled(LogLevel.Debug))
        {
            _logger.LogDebug(
                "Persist requested for {Machine} via {Connection} (CommandTimeoutSeconds={Timeout}, Retry={RetryEnabled}, MaxRetryCount={RetryCount}, MaxRetryDelaySeconds={RetryDelay})",
                machine.Hostname,
                _connectionDescriptor,
                _commandTimeout.TotalSeconds,
                _enableRetryOnFailure,
                _maxRetryCount,
                _maxRetryDelay.TotalSeconds);
        }

        var errors = new List<string>();
        var certsArray = certificates.ToArray();
        var bindingsArray = bindings.ToArray();

        try
        {
#pragma warning disable CA2007 // Asynchronous dispose does not support ConfigureAwait
            await using var connection = new SqlConnection(DescribeConnectionStringForDb());
#pragma warning restore CA2007
            await connection.OpenAsync(ct).ConfigureAwait(false);

            // Step 1: MERGE Machine (returns MachineId)
            int machineId;
            try
            {
                machineId = await UpsertMachineAsync(connection, machine, ct).ConfigureAwait(false);
                _logger.LogDebug("Machine {Machine} upserted with MachineId={MachineId}", machine.Hostname, machineId);
            }
            catch (SqlException ex) when (ex.Number == -2) // Timeout
            {
                var message = $"Machine insert timeout: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Machine insert timeout: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }
            catch (SqlException ex)
            {
                var message = $"Machine insert error: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Machine insert error: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }

            // Step 2: MERGE Certificates (bulk deduplication by Thumbprint)
            int certCount;
            try
            {
                certCount = await UpsertCertificatesAsync(connection, certsArray, ct).ConfigureAwait(false);
                _logger.LogDebug("Upserted {CertCount} certificates", certCount);
            }
            catch (SqlException ex) when (ex.Number == -2)
            {
                var message = $"Certificate insert timeout: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Certificate insert timeout: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }
            catch (SqlException ex)
            {
                var message = $"Certificate insert error: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Certificate insert error: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }

            // Step 3: MERGE MachineCertificates (bindings with corrected MachineId)
            int bindingCount;
            try
            {
                bindingCount = await UpsertMachineCertificatesAsync(
                    connection, machineId, bindingsArray, ct).ConfigureAwait(false);
                _logger.LogDebug("Upserted {BindingCount} machine certificate bindings", bindingCount);
            }
            catch (SqlException ex) when (ex.Number == -2)
            {
                var message = $"Machine certificate insert timeout: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Machine certificate insert timeout: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }
            catch (SqlException ex)
            {
                var message = $"Machine certificate insert error: {ex.Message}";
                errors.Add(message);
                _logger.LogError(ex, "Machine certificate insert error: {SqlErrorMessage}", ex.Message);
                return CreateErrorOutcome(errors);
            }

            if (_logger.IsEnabled(LogLevel.Information))
            {
                _logger.LogInformation(
                    "Persisted harvest for {Machine}: {CertCount} certificates, {BindingCount} bindings",
                    machine.Hostname,
                    certCount,
                    bindingCount);
            }

            return new IngestionOutcome
            {
                CertificatesInserted = certCount,
                CertificatesUpdated = 0, // Track updated vs inserted when differentiation is available
                BindingsInserted = bindingCount,
                BindingsUpdated = 0,
                Errors = errors
            };
        }
        catch (OperationCanceledException ex)
        {
            _logger.LogWarning(ex, "Persistence cancelled for {Machine}", machine.Hostname);
            errors.Add($"Persistence cancelled: {ex.Message}");
            return CreateErrorOutcome(errors);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Unexpected error persisting {Machine}", machine.Hostname);
            errors.Add($"Unexpected error: {ex.Message}");
            return CreateErrorOutcome(errors);
        }
    }

    private async Task<int> UpsertMachineAsync(SqlConnection connection, Machine machine, CancellationToken ct)
    {
        const string sql = @"
            MERGE INTO dbo.Machines AS target
            USING (
                SELECT @Hostname AS Hostname,
                       @FQDN AS FQDN,
                       @Environment AS Environment,
                       @OperatingSystem AS OperatingSystem,
                       @OSVersion AS OSVersion,
                       GETUTCDATE() AS Now
            ) AS source
            ON target.Hostname = source.Hostname
            WHEN MATCHED THEN
                UPDATE SET
                    LastVerifiedAt = source.Now,
                    FQDN = ISNULL(target.FQDN, source.FQDN),
                    Environment = ISNULL(source.Environment, target.Environment),
                    OperatingSystem = ISNULL(source.OperatingSystem, target.OperatingSystem),
                    OSVersion = ISNULL(source.OSVersion, target.OSVersion),
                    IsReachable = 1,
                    ConnectivityFailureCount = 0
            WHEN NOT MATCHED THEN
                INSERT (Hostname, FQDN, Environment, OperatingSystem, OSVersion, IsReachable, FirstDiscoveredAt, LastVerifiedAt)
                VALUES (source.Hostname, source.FQDN, ISNULL(source.Environment, 'Unknown'), source.OperatingSystem, source.OSVersion, 1, source.Now, source.Now);

            SELECT MachineId FROM dbo.Machines WHERE Hostname = @Hostname;
        ";

#pragma warning disable CA2007 // Asynchronous dispose does not support ConfigureAwait
        await using var command = new SqlCommand(sql, connection)
        {
            CommandTimeout = (int)_commandTimeout.TotalSeconds
        };
#pragma warning restore CA2007
        command.Parameters.AddWithValue("@Hostname", (object?)machine.Hostname ?? DBNull.Value);
        command.Parameters.AddWithValue("@FQDN", (object?)machine.Fqdn ?? DBNull.Value);
        command.Parameters.AddWithValue("@Environment", machine.Environment);
        command.Parameters.AddWithValue("@OperatingSystem", DBNull.Value);
        command.Parameters.AddWithValue("@OSVersion", DBNull.Value);

        var result = await command.ExecuteScalarAsync(ct).ConfigureAwait(false);
        return result is int id ? id : throw new InvalidOperationException("Failed to retrieve MachineId after MERGE");
    }

    private async Task<int> UpsertCertificatesAsync(SqlConnection connection, Certificate[] certificates,
        CancellationToken ct)
    {
        if (certificates.Length == 0)
        {
            return 0;
        }

        var sql = @"
            MERGE INTO dbo.Certificates AS target
            USING (
                SELECT @Thumbprint AS Thumbprint,
                       @Subject AS Subject,
                       @Issuer AS Issuer,
                       @SerialNumber AS SerialNumber,
                       @ValidFrom AS ValidFrom,
                       @ValidTo AS ValidTo,
                       @SANs AS SANs,
                       @KeyAlgorithm AS KeyAlgorithm,
                       @KeySize AS KeySize,
                       @SignatureAlgorithm AS SignatureAlgorithm,
                       @IsSelfSigned AS IsSelfSigned,
                       @HasPrivateKey AS HasPrivateKey
            ) AS source
            ON target.Thumbprint = source.Thumbprint
            WHEN MATCHED AND target.DeletedAt IS NOT NULL THEN
                UPDATE SET
                    LastVerifiedAt = GETUTCDATE(),
                    DeletedAt = NULL,
                    DeletedBy = NULL,
                    DeletedReason = NULL
            WHEN MATCHED THEN
                UPDATE SET
                    LastVerifiedAt = GETUTCDATE()
            WHEN NOT MATCHED THEN
                INSERT (Thumbprint, Subject, Issuer, SerialNumber, ValidFrom, ValidTo, SANs, KeyAlgorithm, KeySize, SignatureAlgorithm, IsSelfSigned, HasPrivateKey, FirstDiscoveredAt, LastVerifiedAt)
                VALUES (source.Thumbprint, source.Subject, source.Issuer, source.SerialNumber, source.ValidFrom, source.ValidTo, source.SANs, source.KeyAlgorithm, source.KeySize, source.SignatureAlgorithm, source.IsSelfSigned, source.HasPrivateKey, GETUTCDATE(), GETUTCDATE());
        ";

        int totalUpserted = 0;

        foreach (var cert in certificates)
        {
#pragma warning disable CA2007 // Asynchronous dispose does not support ConfigureAwait
#pragma warning disable IDE0017 // Parameters collection initializer is safe in this context
            // ReSharper disable once UseObjectOrCollectionInitializer
            await using var command = new SqlCommand(sql, connection)
            {
                CommandTimeout = (int)_commandTimeout.TotalSeconds,
                Parameters =
                {
                    new SqlParameter("@Thumbprint", cert.Thumbprint.Value),
                    new SqlParameter("@Subject", cert.Subject),
                    new SqlParameter("@Issuer", cert.Issuer),
                    new SqlParameter("@SerialNumber", cert.SerialNumber),
                    new SqlParameter("@ValidFrom", cert.ValidFrom),
                    new SqlParameter("@ValidTo", cert.ValidTo),
                    new SqlParameter("@SANs", (object?)(SerializeSaNs(cert.SubjectAlternativeNames)) ?? DBNull.Value),
                    new SqlParameter("@KeyAlgorithm", (object?)cert.KeyAlgorithm ?? DBNull.Value),
                    new SqlParameter("@KeySize", cert.KeySize),
                    new SqlParameter("@SignatureAlgorithm", (object?)cert.SignatureAlgorithm ?? DBNull.Value),
                    new SqlParameter("@IsSelfSigned", cert.IsSelfSigned),
                    new SqlParameter("@HasPrivateKey", cert.HasPrivateKey)
                }
            };
#pragma warning restore IDE0017
#pragma warning restore CA2007

            try
            {
                await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
                totalUpserted++;
            }
            catch (SqlException ex) when (ex.Number == 2627) // Unique constraint violation (handled by MERGE MATCHED)
            {
                _logger.LogDebug(ex, "Certificate {Thumbprint} already exists; updated", cert.Thumbprint.Value);
            }
        }

        return totalUpserted;
    }

    private async Task<int> UpsertMachineCertificatesAsync(
        SqlConnection connection,
        int machineId,
        MachineCertificate[] bindings,
        CancellationToken ct)
    {
        if (bindings.Length == 0)
        {
            return 0;
        }

        var sql = @"
            MERGE INTO dbo.MachineCertificates AS target
            USING (
                SELECT @MachineId AS MachineId,
                       @Thumbprint AS Thumbprint,
                       @SourceType AS SourceType,
                       @PathLocation AS PathLocation,
                       @BindingContext AS BindingContext
            ) AS source
            ON target.MachineId = source.MachineId
               AND target.Thumbprint = source.Thumbprint
               AND target.SourceType = source.SourceType
               AND target.PathLocation = source.PathLocation
            WHEN MATCHED AND target.DeletedAt IS NOT NULL THEN
                UPDATE SET
                    LastVerifiedAt = GETUTCDATE(),
                    DeletedAt = NULL,
                    DeletedBy = NULL,
                    DeletedReason = NULL
            WHEN MATCHED THEN
                UPDATE SET
                    LastVerifiedAt = GETUTCDATE()
            WHEN NOT MATCHED THEN
                INSERT (MachineId, Thumbprint, SourceType, PathLocation, BindingContext, FirstDiscoveredAt, LastVerifiedAt)
                VALUES (source.MachineId, source.Thumbprint, source.SourceType, source.PathLocation, source.BindingContext, GETUTCDATE(), GETUTCDATE());
        ";

        int totalUpserted = 0;

        foreach (var binding in bindings)
        {
#pragma warning disable CA2007 // Asynchronous dispose does not support ConfigureAwait
#pragma warning disable IDE0017 // Parameters collection initializer is safe in this context
            // ReSharper disable once UseObjectOrCollectionInitializer
            await using var command = new SqlCommand(sql, connection)
            {
                CommandTimeout = (int)_commandTimeout.TotalSeconds,
                Parameters =
                {
                    new SqlParameter("@MachineId", machineId),
                    new SqlParameter("@Thumbprint", binding.Thumbprint.Value),
                    new SqlParameter("@SourceType", binding.SourceType),
                    new SqlParameter("@PathLocation", binding.PathLocation),
                    new SqlParameter("@BindingContext", (object?)binding.BindingContextJson ?? DBNull.Value)
                }
            };
#pragma warning restore IDE0017
#pragma warning restore CA2007

            try
            {
                await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
                totalUpserted++;
            }
            catch (SqlException ex) when (ex.Number == 2627) // Unique constraint (business key)
            {
                _logger.LogDebug(ex,
                    "Binding {Thumbprint}/{SourceType} already exists for machine {MachineId}; updated",
                    binding.Thumbprint.Value, binding.SourceType, machineId);
            }
        }

        return totalUpserted;
    }

    private static string? SerializeSaNs(IEnumerable<string> sans)
    {
        var sanList = sans.ToList();
        if (sanList.Count == 0)
        {
            return null;
        }

        // Return as JSON array: ["example.com", "*.example.com"]
        return JsonSerializer.Serialize(sanList);
    }

    private static IngestionOutcome CreateErrorOutcome(List<string> errors)
    {
        return new IngestionOutcome
        {
            CertificatesInserted = 0,
            CertificatesUpdated = 0,
            BindingsInserted = 0,
            BindingsUpdated = 0,
            Errors = errors
        };
    }

    private string DescribeConnectionStringForDb() => _connectionString;

    private static string DescribeConnection(string connectionString)
    {
        try
        {
            var builder = new SqlConnectionStringBuilder(connectionString);
            var dataSource = string.IsNullOrWhiteSpace(builder.DataSource) ? "(unknown)" : builder.DataSource;
            var catalog = string.IsNullOrWhiteSpace(builder.InitialCatalog) ? "(default)" : builder.InitialCatalog;
            return $"{dataSource}/{catalog}";
        }
        catch (ArgumentException)
        {
            return "(invalid-connection-string)";
        }
    }
}

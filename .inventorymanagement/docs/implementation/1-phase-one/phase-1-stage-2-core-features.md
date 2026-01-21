# Phase 1 Stage 2: Core Features (Weeks 1.5-2.5)

**Last Updated:** November 25, 2025
**Status:** Ready for Implementation
**Owner:** Carl R. Yeager
**Duration:** ~1 week

---

## Overview

Implement the core certificate collection and persistence logic. This stage builds the WinRM-based OS certificate collector and SQL persistence layer with MERGE upsert statements.

**Primary Goal:** Achieve end-to-end OS certificate harvest from a single test machine to SQL database.

---

## Scope

**In Scope:**
- WinRM OS certificate collector (single machine, no concurrency yet)
- X509Certificate2 property mapping to Domain.Certificate
- SQL persistence layer with MERGE statements (Machines, Certificates, MachineCertificates)
- Machine registration via MERGE upsert (ADR-006)
- Certificate deduplication via thumbprint
- Basic error handling (WinRM connection failures, SQL exceptions)
- Integration tests with Testcontainers (SQL Server)

**Out of Scope:**
- Parallel/concurrent harvesting (Stage 3)
- Retry policies (Stage 3)
- SQLite buffering (Phase 2)
- IIS collection (Phase 2)
- Structured logging (Stage 4)
- Production deployment (Stage 5)

---

## Deliverables

| ID | Deliverable | Location | Acceptance Criteria |
|----|-------------|----------|---------------------|
| D2.1 | WinRM collector | `src/Infrastructure/CertStores/WinRmOSCollector.cs` | Successfully harvests certs from test machine |
| D2.2 | Certificate mapper | `src/Infrastructure/CertStores/CertificateMapper.cs` | Maps X509Certificate2 to Domain.Certificate correctly |
| D2.3 | SQL persistence | `src/Infrastructure/Persistence/SqlServerPersistence.cs` | MERGE statements work for all three tables |
| D2.4 | Port interfaces | `src/Domain/Interfaces/ICertificateStoreReader.cs`, `IIngestionWriter.cs` | Contracts updated per ADR-002 |
| D2.5 | Integration tests | `tests/Infrastructure.Tests/Persistence/` | SQL MERGE logic validated with Testcontainers |
| D2.6 | WinRM connectivity test | `scripts/Test-WinRmConnectivity.ps1` | Pre-deployment validation script |

---

## Tasks

### Task Group A: Port Interfaces

**Duration:** 0.5 days

Define the contracts between Domain and Infrastructure layers per hexagonal architecture.

#### A1: Define ICertificateStoreReader

**File:** `src/Domain/Interfaces/ICertificateStoreReader.cs`

```csharp
namespace Domain.Interfaces;

using Domain.Certificates;

/// <summary>
/// Port interface for certificate collection from remote stores.
/// Implementations: WinRmOSCollector, IISBindingCollector, F5RestClient, RepositoryPfxReader
/// </summary>
public interface ICertificateStoreReader
{
    /// <summary>
    /// Collects certificates from a target machine/device.
    /// </summary>
    /// <param name="targetIdentifier">FQDN for WinRM, IP for F5, path for Repository</param>
    /// <param name="ct">Cancellation token</param>
    /// <returns>Canonical certificates + binding metadata</returns>
    Task<CertificateCollection> CollectAsync(string targetIdentifier, CancellationToken ct);
}

/// <summary>
/// Result of certificate collection operation.
/// </summary>
public sealed class CertificateCollection
{
    public required string TargetIdentifier { get; init; }  // server01.cambridge.edu
    public required Certificate[] Certificates { get; init; }
    public required MachineCertificateLocation[] Locations { get; init; }
    public required DateTimeOffset CollectedAt { get; init; }
    public bool IsSuccess { get; init; }
    public string? ErrorMessage { get; init; }
}

/// <summary>
/// Location metadata for a certificate (where it was found).
/// </summary>
public sealed class MachineCertificateLocation
{
    public required string Thumbprint { get; init; }
    public required string SourceType { get; init; }      // OS, IIS, F5, Repository
    public required string PathLocation { get; init; }    // LocalMachine\My
    public string? BindingContext { get; init; }          // JSON metadata
}
```

#### A2: Define IIngestionWriter

**File:** `src/Domain/Interfaces/IIngestionWriter.cs`

```csharp
namespace Domain.Interfaces;

using Domain.Certificates;
using Domain.Machines;

/// <summary>
/// Port interface for persisting harvest results to storage.
/// Primary implementation: SqlServerPersistence
/// Future: SQLite buffer (Phase 2)
/// </summary>
public interface IIngestionWriter
{
    /// <summary>
    /// Persists machine registration and certificate harvest results.
    /// Handles deduplication and upserts.
    /// </summary>
    Task<IngestionOutcome> PersistAsync(
        Machine machine,
        Certificate[] certificates,
        MachineCertificateLocation[] locations,
        CancellationToken cancellationToken);
}

/// <summary>
/// Result of persistence operation.
/// </summary>
public sealed class IngestionOutcome
{
    public int MachineId { get; init; }
    public int CertificatesUpserted { get; init; }
    public int BindingsUpserted { get; init; }
    public bool IsSuccess { get; init; }
    public string? ErrorMessage { get; init; }
    public TimeSpan Duration { get; init; }
}
```

---

### Task Group B: WinRM Certificate Collector

**Duration:** 2 days

#### B1: Implement WinRmOSCollector

**File:** `src/Infrastructure/CertStores/WinRmOSCollector.cs`

```csharp
namespace Infrastructure.CertStores;

using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Domain.Certificates;
using Domain.Interfaces;
using Microsoft.Extensions.Logging;

/// <summary>
/// Collects certificates from Windows certificate stores via WinRM PowerShell remoting.
/// Phase 1: Sequential, single-threaded. Phase 2: Parallel with throttling.
/// </summary>
public sealed class WinRmOSCollector : ICertificateStoreReader
{
    private readonly ILogger<WinRmOSCollector> _logger;
    private readonly CertificateMapper _mapper;

    // Certificate stores to enumerate
    private static readonly string[] StorePaths =
    {
        @"Cert:\\LocalMachine\\My",       // Personal
        @"Cert:\\LocalMachine\\Root",     // Trusted Root
        @"Cert:\\LocalMachine\\CA",       // Intermediate CA
        @"Cert:\\LocalMachine\\AuthRoot"  // Third-party Root CA
    };

    public WinRmOSCollector(ILogger<WinRmOSCollector> logger, CertificateMapper mapper)
    {
        _logger = logger;
        _mapper = mapper;
    }

    public async Task<CertificateCollection> CollectAsync(string targetFqdn, CancellationToken cancellationToken)
    {
        var startTime = DateTimeOffset.UtcNow;

        try
        {
            _logger.LogInformation("Starting OS certificate collection for {Target}", targetFqdn);

            // Create WinRM connection
            var connectionInfo = new WSManConnectionInfo(
                new Uri($"http://{targetFqdn}:5985/wsman"),
                "http://schemas.microsoft.com/powershell/Microsoft.PowerShell",
                credentials: null);  // Uses current Windows identity (Kerberos)

            connectionInfo.OperationTimeout = (int)TimeSpan.FromMinutes(2).TotalMilliseconds;
            connectionInfo.OpenTimeout = (int)TimeSpan.FromSeconds(30).TotalMilliseconds;

            using var runspace = RunspaceFactory.CreateRunspace(connectionInfo);
            runspace.Open();

            var certificates = new List<Certificate>();
            var locations = new List<MachineCertificateLocation>();

            // Enumerate each certificate store
            foreach (var storePath in StorePaths)
            {
                cancellationToken.ThrowIfCancellationRequested();

                var (certs, locs) = await CollectFromStoreAsync(runspace, storePath, cancellationToken);
                certificates.AddRange(certs);
                locations.AddRange(locs);
            }

            runspace.Close();

            _logger.LogInformation(
                "Collected {CertCount} certificates from {StoreCount} stores on {Target}",
                certificates.Count, StorePaths.Length, targetFqdn);

            return new CertificateCollection
            {
                TargetIdentifier = targetFqdn,
                Certificates = certificates.ToArray(),
                Locations = locations.ToArray(),
                CollectedAt = startTime,
                IsSuccess = true
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to collect certificates from {Target}", targetFqdn);

            return CertificateCollectionFailed(targetFqdn, startTime, ex);
        }
    }

    private static CertificateCollection CertificateCollectionFailed(
        string targetFqdn,
        DateTimeOffset collectedAt,
        Exception exception) => new()
    {
        TargetIdentifier = targetFqdn,
        Certificates = Array.Empty<Certificate>(),
        Locations = Array.Empty<MachineCertificateLocation>(),
        CollectedAt = collectedAt,
        IsSuccess = false,
        ErrorMessage = exception.Message
    };

    private async Task<(Certificate[] Certs, MachineCertificateLocation[] Locations)> CollectFromStoreAsync(
        Runspace runspace, string storePath, CancellationToken cancellationToken)
    {
        using var pipeline = runspace.CreatePipeline();

        // PowerShell command to enumerate certificates
        var script = $@"
            Get-ChildItem -Path '{storePath}' -ErrorAction SilentlyContinue |
            Select-Object Thumbprint, Subject, Issuer, NotBefore, NotAfter, HasPrivateKey,
                          @{{Name='SANs'; Expression={{($_.Extensions | Where-Object {{$_.Oid.Value -eq '2.5.29.17'}}).Format($false)}}}},
                          @{{Name='KeyAlgorithm'; Expression={{$_.PublicKey.Oid.FriendlyName}}}},
                          @{{Name='KeySize'; Expression={{$_.PublicKey.Key.KeySize}}}},
                          @{{Name='SignatureAlgorithm'; Expression={{$_.SignatureAlgorithm.FriendlyName}}}},
                          SerialNumber
        ";

        pipeline.Commands.AddScript(script);

        var results = await Task.Run(() => pipeline.Invoke(), cancellationToken);

        var certificates = new List<Certificate>();
        var locations = new List<MachineCertificateLocation>();

        foreach (var result in results)
        {
            try
            {
                var cert = _mapper.MapFromPSObject(result, storePath);
                certificates.Add(cert.Certificate);
                locations.Add(cert.Location);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to parse certificate from {Store}", storePath);
            }
        }

        return (certificates.ToArray(), locations.ToArray());
    }
}
```

#### B2: Implement CertificateMapper

**File:** `src/Infrastructure/CertStores/CertificateMapper.cs`

```csharp
namespace Infrastructure.CertStores;

using System.Management.Automation;
using Domain.Certificates;
using Domain.Interfaces;
using Domain.Services;

/// <summary>
/// Maps PowerShell certificate objects and X509Certificate2 to Domain.Certificate.
/// </summary>
public sealed class CertificateMapper
{
    public (Certificate Certificate, MachineCertificateLocation Location) MapFromPSObject(
        PSObject psObject, string storePath)
    {
        var thumbprint = CertificateNormalizer.NormalizeThumbprint(
            psObject.Properties["Thumbprint"]?.Value?.ToString() ?? string.Empty);

        var subject = psObject.Properties["Subject"]?.Value?.ToString() ?? string.Empty;
        var issuer = psObject.Properties["Issuer"]?.Value?.ToString() ?? string.Empty;

        var notBefore = DateTime.Parse(psObject.Properties["NotBefore"]?.Value?.ToString() ?? DateTime.UtcNow.ToString());
        var notAfter = DateTime.Parse(psObject.Properties["NotAfter"]?.Value?.ToString() ?? DateTime.UtcNow.AddYears(1).ToString());

        var hasPrivateKey = bool.Parse(psObject.Properties["HasPrivateKey"]?.Value?.ToString() ?? "false");

        var keyAlgorithm = psObject.Properties["KeyAlgorithm"]?.Value?.ToString() ?? "Unknown";
        var keySize = int.Parse(psObject.Properties["KeySize"]?.Value?.ToString() ?? "0");
        var signatureAlgorithm = psObject.Properties["SignatureAlgorithm"]?.Value?.ToString() ?? "Unknown";
        var serialNumber = psObject.Properties["SerialNumber"]?.Value?.ToString() ?? string.Empty;

        // Parse SANs
        var sanRaw = psObject.Properties["SANs"]?.Value?.ToString() ?? string.Empty;
        var sans = ParseSANs(sanRaw);

        var isSelfSigned = subject.Equals(issuer, StringComparison.OrdinalIgnoreCase);

        var certificate = new Certificate
        {
            Thumbprint = thumbprint,
            Subject = subject,
            Issuer = issuer,
            SubjectAlternativeNames = sans,
            ValidFrom = new DateTimeOffset(notBefore, TimeSpan.Zero),
            ValidTo = new DateTimeOffset(notAfter, TimeSpan.Zero),
            HasPrivateKey = hasPrivateKey,
            IsSelfSigned = isSelfSigned,
            KeyAlgorithm = keyAlgorithm,
            KeySize = keySize,
            SignatureAlgorithm = signatureAlgorithm,
            SerialNumber = serialNumber
        };

        var location = new MachineCertificateLocation
        {
            Thumbprint = thumbprint,
            SourceType = "OS",
            PathLocation = storePath  // Cert:\LocalMachine\My
        };

        return (certificate, location);
    }

    private string[] ParseSANs(string sanRaw)
    {
        if (string.IsNullOrWhiteSpace(sanRaw))
            return Array.Empty<string>();

        return sanRaw
            .Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => s.StartsWith("DNS Name=", StringComparison.OrdinalIgnoreCase))
            .Select(s => s.Substring("DNS Name=".Length))
            .ToArray();
    }
}
```

---

### Task Group C: SQL Persistence

**Duration:** 2 days

#### C1: Implement SqlServerPersistence

**File:** `src/Infrastructure/Persistence/SqlServerPersistence.cs`

```csharp
namespace Infrastructure.Persistence;

using System.Data;
using System.Diagnostics;
using Domain.Certificates;
using Domain.Interfaces;
using Domain.Machines;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

/// <summary>
/// SQL Server persistence adapter using MERGE statements for upserts.
/// Implements ADR-006 (Machine registration via upsert), ADR-007 (Surrogate key).
/// </summary>
public sealed class SqlServerPersistence : IIngestionWriter
{
    private readonly string _connectionString;
    private readonly ILogger<SqlServerPersistence> _logger;

    public SqlServerPersistence(IConfiguration configuration, ILogger<SqlServerPersistence> logger)
    {
        _connectionString = configuration.GetConnectionString("InventoryDatabase")
            ?? throw new ArgumentException("Missing connection string: InventoryDatabase");
        _logger = logger;
    }

    public async Task<IngestionOutcome> PersistAsync(
        Machine machine,
        Certificate[] certificates,
        MachineCertificateLocation[] locations,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();

        try
        {
            await using var connection = new SqlConnection(_connectionString);
            await connection.OpenAsync(cancellationToken);

            // Step 1: Upsert Machine (returns MachineId)
            var machineId = await UpsertMachineAsync(connection, machine, cancellationToken);

            // Step 2: Upsert Certificates (deduplicated by Thumbprint)
            var certCount = await UpsertCertificatesAsync(connection, certificates, cancellationToken);

            // Step 3: Upsert MachineCertificates (bindings)
            var bindingCount = await UpsertMachineCertificatesAsync(
                connection, machineId, locations, cancellationToken);

            stopwatch.Stop();

            _logger.LogInformation(
                "Persisted harvest for {Machine}: {CertCount} certificates, {BindingCount} bindings in {Duration}ms",
                machine.FQDN, certCount, bindingCount, stopwatch.ElapsedMilliseconds);

            return new IngestionOutcome
            {
                MachineId = machineId,
                CertificatesUpserted = certCount,
                BindingsUpserted = bindingCount,
                IsSuccess = true,
                Duration = stopwatch.Elapsed
            };
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            _logger.LogError(ex, "Failed to persist harvest for {Machine}", machine.FQDN);

            return new IngestionOutcome
            {
                IsSuccess = false,
                ErrorMessage = ex.Message,
                Duration = stopwatch.Elapsed
            };
        }
    }

    private async Task<int> UpsertMachineAsync(SqlConnection connection, Machine machine, CancellationToken ct)
    {
        const string sql = @"
            MERGE INTO Machines AS target
            USING (SELECT @Hostname AS Hostname, @FQDN AS FQDN, @Environment AS Environment) AS source
            ON target.Hostname = source.Hostname
            WHEN MATCHED THEN
                UPDATE SET
                    LastSeen = SYSDATETIMEOFFSET(),
                    WinRMStatus = 'Reachable',
                    FQDN = source.FQDN,
                    IsActive = 1
            WHEN NOT MATCHED THEN
                INSERT (Hostname, FQDN, Environment, FirstSeen, LastSeen, WinRMStatus, IsActive)
                VALUES (source.Hostname, source.FQDN, source.Environment,
                        SYSDATETIMEOFFSET(), SYSDATETIMEOFFSET(), 'Reachable', 1)
            OUTPUT INSERTED.MachineId;
        ";

        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@Hostname", machine.Hostname);
        command.Parameters.AddWithValue("@FQDN", (object?)machine.FQDN ?? DBNull.Value);
        command.Parameters.AddWithValue("@Environment", machine.Environment);

        var machineId = await command.ExecuteScalarAsync(ct);
        return Convert.ToInt32(machineId);
    }

    private async Task<int> UpsertCertificatesAsync(
        SqlConnection connection, Certificate[] certificates, CancellationToken ct)
    {
        if (certificates.Length == 0)
            return 0;

        // Use Table-Valued Parameter for bulk MERGE
        var dataTable = new DataTable();
        dataTable.Columns.Add("Thumbprint", typeof(string));
        dataTable.Columns.Add("Subject", typeof(string));
        dataTable.Columns.Add("Issuer", typeof(string));
        dataTable.Columns.Add("SubjectAlternativeNames", typeof(string));
        dataTable.Columns.Add("ValidFrom", typeof(DateTimeOffset));
        dataTable.Columns.Add("ValidTo", typeof(DateTimeOffset));
        dataTable.Columns.Add("HasPrivateKey", typeof(bool));
        dataTable.Columns.Add("IsSelfSigned", typeof(bool));
        dataTable.Columns.Add("KeyAlgorithm", typeof(string));
        dataTable.Columns.Add("KeySize", typeof(int));
        dataTable.Columns.Add("SignatureAlgorithm", typeof(string));
        dataTable.Columns.Add("SerialNumber", typeof(string));

        foreach (var cert in certificates)
        {
            var sanJson = cert.SubjectAlternativeNames.Length > 0
                ? System.Text.Json.JsonSerializer.Serialize(cert.SubjectAlternativeNames)
                : (object)DBNull.Value;

            dataTable.Rows.Add(
                cert.Thumbprint, cert.Subject, cert.Issuer, sanJson,
                cert.ValidFrom, cert.ValidTo, cert.HasPrivateKey, cert.IsSelfSigned,
                cert.KeyAlgorithm, cert.KeySize, cert.SignatureAlgorithm, cert.SerialNumber);
        }

        const string sql = @"
            MERGE INTO Certificates AS target
            USING @CertData AS source
            ON target.Thumbprint = source.Thumbprint
            WHEN MATCHED THEN
                UPDATE SET LastUpdated = SYSDATETIMEOFFSET()
            WHEN NOT MATCHED THEN
                INSERT (Thumbprint, Subject, Issuer, SubjectAlternativeNames, ValidFrom, ValidTo,
                        HasPrivateKey, IsSelfSigned, KeyAlgorithm, KeySize, SignatureAlgorithm, SerialNumber)
                VALUES (source.Thumbprint, source.Subject, source.Issuer, source.SubjectAlternativeNames,
                        source.ValidFrom, source.ValidTo, source.HasPrivateKey, source.IsSelfSigned,
                        source.KeyAlgorithm, source.KeySize, source.SignatureAlgorithm, source.SerialNumber);
        ";

        await using var command = new SqlCommand(sql, connection);
        var param = command.Parameters.AddWithValue("@CertData", dataTable);
        param.SqlDbType = SqlDbType.Structured;
        param.TypeName = "dbo.CertificateTableType";  // Requires creating TVP type in Phase 1 Week 1

        return await command.ExecuteNonQueryAsync(ct);
    }

    private async Task<int> UpsertMachineCertificatesAsync(
        SqlConnection connection, int machineId, MachineCertificateLocation[] locations, CancellationToken ct)
    {
        if (locations.Length == 0)
            return 0;

        var dataTable = new DataTable();
        dataTable.Columns.Add("MachineId", typeof(int));
        dataTable.Columns.Add("Thumbprint", typeof(string));
        dataTable.Columns.Add("SourceType", typeof(string));
        dataTable.Columns.Add("PathLocation", typeof(string));
        dataTable.Columns.Add("BindingContext", typeof(string));

        foreach (var loc in locations)
        {
            dataTable.Rows.Add(
                machineId, loc.Thumbprint, loc.SourceType, loc.PathLocation,
                (object?)loc.BindingContext ?? DBNull.Value);
        }

        const string sql = @"
            MERGE INTO MachineCertificates AS target
            USING @BindingData AS source
            ON target.MachineId = source.MachineId
               AND target.Thumbprint = source.Thumbprint
               AND target.SourceType = source.SourceType
               AND target.PathLocation = source.PathLocation
            WHEN MATCHED THEN
                UPDATE SET
                    LastVerified = SYSDATETIMEOFFSET(),
                    DeletedAt = NULL  -- Resurrect if previously soft-deleted
            WHEN NOT MATCHED THEN
                INSERT (MachineId, Thumbprint, SourceType, PathLocation, BindingContext, LastVerified)
                VALUES (source.MachineId, source.Thumbprint, source.SourceType, source.PathLocation,
                        source.BindingContext, SYSDATETIMEOFFSET());
        ";

        await using var command = new SqlCommand(sql, connection);
        var param = command.Parameters.AddWithValue("@BindingData", dataTable);
        param.SqlDbType = SqlDbType.Structured;
        param.TypeName = "dbo.MachineCertificateTableType";  // Requires creating TVP type in Phase 1 Week 1

        return await command.ExecuteNonQueryAsync(ct);
    }
}
```

**NOTE:** Requires creating Table-Valued Parameter types in SQL:

**File:** `src/Infrastructure/Persistence/Schema/002-table-valued-parameters.sql`

```sql
-- Table-Valued Parameters for bulk MERGE operations

USE ProdSpt_Inventory;
GO

-- TVP for Certificates
IF TYPE_ID('dbo.CertificateTableType') IS NULL
BEGIN
    CREATE TYPE dbo.CertificateTableType AS TABLE (
        Thumbprint NVARCHAR(64) NOT NULL,  -- Supports SHA-256 (64) and SHA-1 (40)
        Subject NVARCHAR(500) NOT NULL,
        Issuer NVARCHAR(500) NOT NULL,
        SubjectAlternativeNames NVARCHAR(MAX) NULL,
        ValidFrom DATETIMEOFFSET NOT NULL,
        ValidTo DATETIMEOFFSET NOT NULL,
        HasPrivateKey BIT NOT NULL,
        IsSelfSigned BIT NOT NULL,
        KeyAlgorithm NVARCHAR(50) NOT NULL,
        KeySize INT NOT NULL,
        SignatureAlgorithm NVARCHAR(50) NOT NULL,
        SerialNumber NVARCHAR(100) NOT NULL
    );

    PRINT 'Created type: dbo.CertificateTableType';
END
GO

-- TVP for MachineCertificates
IF TYPE_ID('dbo.MachineCertificateTableType') IS NULL
BEGIN
    CREATE TYPE dbo.MachineCertificateTableType AS TABLE (
        MachineId INT NOT NULL,
        Thumbprint NVARCHAR(64) NOT NULL,  -- Supports SHA-256 (64) and SHA-1 (40)
        SourceType NVARCHAR(20) NOT NULL,
        PathLocation NVARCHAR(500) NOT NULL,
        BindingContext NVARCHAR(MAX) NULL
    );

    PRINT 'Created type: dbo.MachineCertificateTableType';
END
GO
```

---

### Task Group D: Integration Testing

**Duration:** 1.5 days

#### D1: Setup Testcontainers for SQL Server

**File:** `tests/Infrastructure.Tests/Persistence/SqlServerPersistenceTests.cs`

```csharp
namespace Infrastructure.Tests.Persistence;

using Domain.Certificates;
using Domain.Interfaces;
using Domain.Machines;
using Infrastructure.Persistence;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Testcontainers.MsSql;
using Xunit;

public sealed class SqlServerPersistenceTests : IAsyncLifetime
{
    private readonly MsSqlContainer _sqlContainer = new MsSqlBuilder()
        .WithImage("mcr.microsoft.com/mssql/server:2022-latest")
        .Build();

    private SqlServerPersistence _sut = null!;

    public async Task InitializeAsync()
    {
        await _sqlContainer.StartAsync();

        // Deploy schema
        var connectionString = _sqlContainer.GetConnectionString();
        await DeploySchemaAsync(connectionString);

        // Initialize SUT
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:InventoryDatabase"] = connectionString
            })
            .Build();

        var logger = LoggerFactory.Create(b => b.AddConsole()).CreateLogger<SqlServerPersistence>();
        _sut = new SqlServerPersistence(config, logger);
    }

    public async Task DisposeAsync()
    {
        await _sqlContainer.DisposeAsync();
    }

    [Fact]
    public async Task PersistAsync_UpsertsMachineAndCertificates()
    {
        // Arrange
        var machine = new Machine
        {
            Hostname = "SERVER01",
            FQDN = "server01.test.cambridge.edu",
            Environment = "Test",
            FirstSeen = DateTimeOffset.UtcNow,
            LastSeen = DateTimeOffset.UtcNow
        };

        var certificates = new[]
        {
            new Certificate
            {
                Thumbprint = "ABC123DEF456789012345678901234567890ABCD",
                Subject = "CN=test.cambridge.edu",
                Issuer = "CN=TestCA",
                ValidFrom = DateTimeOffset.UtcNow.AddDays(-30),
                ValidTo = DateTimeOffset.UtcNow.AddDays(365),
                KeyAlgorithm = "RSA",
                KeySize = 2048,
                SignatureAlgorithm = "sha256RSA",
                SerialNumber = "123456"
            }
        };

        var locations = new[]
        {
            new MachineCertificateLocation
            {
                Thumbprint = certificates[0].Thumbprint,
                SourceType = "OS",
                PathLocation = @"Cert:\LocalMachine\My"
            }
        };

        // Act
        var result = await _sut.PersistAsync(machine, certificates, locations, CancellationToken.None);

        // Assert
        Assert.True(result.IsSuccess);
        Assert.True(result.MachineId > 0);
        Assert.Equal(1, result.CertificatesUpserted);
        Assert.Equal(1, result.BindingsUpserted);
    }

    [Fact]
    public async Task PersistAsync_DeduplicatesCertificates()
    {
        // Test that same certificate on multiple machines creates single Certificates row
        // but multiple MachineCertificates rows

        // (Implementation left as exercise - test deduplication logic)
    }

    private async Task DeploySchemaAsync(string connectionString)
    {
        // Read and execute schema DDL scripts
        var schemaScript = await File.ReadAllTextAsync(
            Path.Combine(TestContext.GetSolutionRoot(), "src/Infrastructure/Persistence/Schema/001-initial-schema.sql"));

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();

        // Execute batches (split on GO)
        var batches = schemaScript.Split(new[] { "\nGO\n", "\nGO\r\n" }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var batch in batches)
        {
            if (string.IsNullOrWhiteSpace(batch)) continue;

            await using var command = new SqlCommand(batch, connection);
            await command.ExecuteNonQueryAsync();
        }
    }
}

internal static class TestContext
{
    public static string GetSolutionRoot()
    {
        var dir = Directory.GetCurrentDirectory();
        while (dir != null && !File.Exists(Path.Combine(dir, "InventoryManagement.sln")))
        {
            dir = Directory.GetParent(dir)?.FullName;
        }
        return dir ?? throw new InvalidOperationException("Solution root not found");
    }
}
```

---

### Task Group E: Pre-Deployment Validation

**Duration:** 0.5 days

#### E1: WinRM Connectivity Test Script

**File:** `scripts/Test-WinRmConnectivity.ps1`

```powershell
<#
.SYNOPSIS
    Tests WinRM connectivity to target servers before deploying certificate harvest service.

.DESCRIPTION
    Validates:
    - WinRM service is running
    - Firewall allows 5985/5986
    - Current user has admin rights on target
    - Certificate enumeration works

.EXAMPLE
    .\Test-WinRmConnectivity.ps1 -TargetServers @("server01.cambridge.edu", "server02.cambridge.edu")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$TargetServers
)

$results = @()

foreach ($server in $TargetServers) {
    Write-Host "Testing $server..." -ForegroundColor Cyan

    $result = [PSCustomObject]@{
        Server = $server
        WinRMReachable = $false
        AdminRights = $false
        CertStoreReadable = $false
        CertificateCount = 0
        ErrorMessage = $null
    }

    try {
        # Test WinRM connectivity
        $session = New-PSSession -ComputerName $server -ErrorAction Stop
        $result.WinRMReachable = $true

        # Test certificate enumeration
        $certCount = Invoke-Command -Session $session -ScriptBlock {
            (Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop).Count
        } -ErrorAction Stop

        $result.AdminRights = $true
        $result.CertStoreReadable = $true
        $result.CertificateCount = $certCount

        Remove-PSSession -Session $session

        Write-Host "  ✓ WinRM reachable" -ForegroundColor Green
        Write-Host "  ✓ Admin rights verified" -ForegroundColor Green
        Write-Host "  ✓ Cert store readable ($certCount certs)" -ForegroundColor Green
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
        Write-Host "  ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    $results += $result
}

Write-Host "`nSummary:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$successCount = ($results | Where-Object { $_.WinRMReachable -and $_.AdminRights }).Count
Write-Host "$successCount of $($TargetServers.Count) servers ready for harvest" -ForegroundColor $(
    if ($successCount -eq $TargetServers.Count) { 'Green' } else { 'Yellow' }
)
```

---

## Acceptance Criteria

| ID | Criteria | Validation Method |
|----|----------|-------------------|
| AC1 | WinRM collector harvests certs | Run against test machine, verify results |
| AC2 | Certificate mapping correct | Unit tests pass for CertificateMapper |
| AC3 | SQL MERGE statements work | Integration tests pass with Testcontainers |
| AC4 | Machine registration upsert | Verify MERGE creates/updates Machine row |
| AC5 | Certificate deduplication | Same thumbprint on 2 machines → 1 Certificates row, 2 MachineCertificates rows |
| AC6 | Port interfaces defined | Code compiles, interfaces implemented |
| AC7 | WinRM pre-check passes | Test script succeeds for target servers |

---

## Dependencies

**Required Before Starting:**
- Stage 1 complete (Domain model, SQL schema deployed)
- Test machine with WinRM enabled and accessible
- SQL Server test instance with Stage 1 schema

**Provides to Next Stage:**
- Working end-to-end harvest (single machine)
- Persistence layer ready for scale (Stage 3)
- Baseline for error handling and retry (Stage 3)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| WinRM access denied | High | Run connectivity test script before deployment |
| X509 property mapping errors | Medium | Comprehensive unit tests for CertificateMapper |
| SQL TVP performance issues | Low | Benchmark with 1000+ certs in integration test |

---

## Success Metrics

- **End-to-end harvest:** 1 test machine → SQL in <30 seconds
- **Certificate accuracy:** 100% of certs mapped correctly (validated manually)
- **Integration test coverage:** ≥80% for SqlServerPersistence
- **Zero SQL constraint violations** during MERGE operations

---

## Next Stage

**Stage 3: Scale (Weeks 2.5-3)** - Implement sequential multi-machine harvesting, error handling, retry policies, and connection management.

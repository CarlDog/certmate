namespace Infrastructure.CertStores;

using System.Globalization;
using System.Linq;
using System.Management.Automation.Runspaces;
using Domain.Interfaces;
using Domain.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Adapter for remote certificate collection via WinRM.
/// PULL-ONLY: No agents installed on remote machines.
/// Enumerates Windows certificate stores via PowerShell remoting.
/// </summary>
public sealed class RemoteWinRmCertCollector : ICertificateStoreReader
{
    // Standard Windows certificate store paths
    private static readonly string[] CertificateStorePaths =
    {
        @"Cert:\LocalMachine\My", // Personal certificates
        @"Cert:\LocalMachine\Root", // Root CA certificates
        @"Cert:\LocalMachine\CA", // Intermediate CA certificates
        @"Cert:\LocalMachine\AuthRoot" // Trusted root certificates
    };

    private static readonly char[] SanSeparators = [','];

    private readonly WinRmCollectorSettings _settings;
    private readonly ILogger<RemoteWinRmCertCollector> _logger;

    public RemoteWinRmCertCollector(WinRmCollectorSettings settings, ILogger<RemoteWinRmCertCollector> logger)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(logger);

        _settings = settings;
        _logger = logger;
    }

    public Task<CertificateCollection> CollectAsync(string targetIdentifier, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetIdentifier);

        ct.ThrowIfCancellationRequested();

        var collectedAt = DateTimeOffset.UtcNow;

        try
        {
            if (_logger.IsEnabled(LogLevel.Information))
            {
                _logger.LogInformation(
                    "Starting WinRM collection for {Target} using account {Account} (SSL={UseSsl}, SkipCA={SkipCa}, SkipCN={SkipCn})",
                    targetIdentifier,
                    _settings.ServiceAccountUsername,
                    _settings.UseSsl,
                    _settings.SkipCertificateAuthorityValidation,
                    _settings.SkipCommonNameValidation);
            }

            // Using default credentials until ISecretProvider supplies service account credentials.
            var connectionInfo = new WSManConnectionInfo
            {
                ComputerName = targetIdentifier,
                Port = _settings.UseSsl ? 5986 : 5985,
                OperationTimeout = (int)_settings.Timeout.TotalMilliseconds,
                MaxConnectionRetryCount = 2
            };

            // Skip certificate validation if configured (useful for test/dev)
            if (_settings.SkipCertificateAuthorityValidation || _settings.SkipCommonNameValidation)
            {
                connectionInfo.SkipCACheck = _settings.SkipCertificateAuthorityValidation;
                connectionInfo.SkipCNCheck = _settings.SkipCommonNameValidation;
            }

            var certificates = new List<Domain.Certificates.Certificate>();
            var bindings = new List<CertificateBinding>();

            // Create runspace and execute collection
            using var runspace = RunspaceFactory.CreateRunspace(connectionInfo);

            try
            {
                runspace.Open();

                _logger.LogDebug("WinRM runspace opened for {Target}", targetIdentifier);

                // Enumerate each certificate store
                foreach (var storePath in CertificateStorePaths)
                {
                    ct.ThrowIfCancellationRequested();

                    try
                    {
                        var (storeCerts, storeBindings) = CollectFromStore(
                            runspace, storePath, targetIdentifier);

                        certificates.AddRange(storeCerts);
                        bindings.AddRange(storeBindings);

                        _logger.LogDebug(
                            "Collected {CertCount} certificates from {Store} on {Target}",
                            storeCerts.Length,
                            storePath,
                            targetIdentifier);
                    }
                    catch (System.Management.Automation.Remoting.PSRemotingTransportException ex)
                    {
                        _logger.LogWarning(
                            ex,
                            "WinRM transport error collecting from {Store} on {Target}",
                            storePath,
                            targetIdentifier);
                        // Continue with other stores on error
                    }
                    catch (System.Management.Automation.RuntimeException ex)
                    {
                        _logger.LogWarning(
                            ex,
                            "PowerShell error collecting certificates from {Store} on {Target}",
                            storePath,
                            targetIdentifier);
                        // Continue with other stores on error
                    }
                }

                if (_logger.IsEnabled(LogLevel.Information))
                {
                    _logger.LogInformation(
                        "WinRM collection completed for {Target}: {CertCount} certificates from {StoreCount} stores",
                        targetIdentifier,
                        certificates.Count,
                        CertificateStorePaths.Length);
                }

                var result = new CertificateCollection
                {
                    TargetIdentifier = targetIdentifier,
                    Certificates = certificates.ToArray(),
                    Bindings = bindings.ToArray(),
                    CollectedAt = collectedAt,
                    IsSuccess = true,
                    ErrorMessage = null
                };

                return Task.FromResult(result);
            }
            finally
            {
                if (runspace.RunspaceStateInfo.State == RunspaceState.Opened)
                {
                    runspace.Close();
                    _logger.LogDebug("WinRM runspace closed for {Target}", targetIdentifier);
                }
            }
        }
        catch (OperationCanceledException ex)
        {
            _logger.LogWarning(ex, "WinRM collection cancelled for {Target}", targetIdentifier);
            return Task.FromResult(CertificateCollection.Failed(
                targetIdentifier,
                $"Collection cancelled: {ex.Message}",
                collectedAt));
        }
        catch (System.Management.Automation.Remoting.PSRemotingTransportException ex)
        {
            _logger.LogError(
                ex,
                "WinRM transport connection failed for {Target}: {ErrorMessage}",
                targetIdentifier,
                ex.Message);

            return Task.FromResult(CertificateCollection.Failed(
                targetIdentifier,
                $"WinRM connection error: {ex.Message}",
                collectedAt));
        }
        catch (InvalidOperationException ex)
        {
            _logger.LogError(
                ex,
                "Invalid WinRM operation for {Target}: {ErrorMessage}",
                targetIdentifier,
                ex.Message);

            return Task.FromResult(CertificateCollection.Failed(
                targetIdentifier,
                $"Operation error: {ex.Message}",
                collectedAt));
        }
        catch (System.Management.Automation.RuntimeException ex)
        {
            _logger.LogError(
                ex,
                "PowerShell runtime error for {Target}: {ErrorMessage}",
                targetIdentifier,
                ex.Message);

            return Task.FromResult(CertificateCollection.Failed(
                targetIdentifier,
                $"PowerShell error: {ex.Message}",
                collectedAt));
        }
    }

    private (Domain.Certificates.Certificate[] Certificates, CertificateBinding[] Bindings)
        CollectFromStore(
            Runspace runspace,
            string storePath,
            string targetIdentifier)
    {
        using var pipeline = runspace.CreatePipeline();

        // PowerShell command to enumerate and extract certificate properties
        var script = $@"
            Get-ChildItem -Path '{storePath}' -ErrorAction Stop |
            Select-Object Thumbprint, Subject, Issuer, NotBefore, NotAfter, HasPrivateKey, SerialNumber,
                          @{{Name='SANs'; Expression={{
                              try {{
                                  $sanExt = $_.Extensions | Where-Object {{$_.Oid.Value -eq '2.5.29.17'}}
                                  if ($sanExt) {{ $sanExt.Format($true) }} else {{ @() }}
                              }} catch {{ @() }}
                          }}}},
                          @{{Name='KeyAlgorithm'; Expression={{$_.PublicKey.Oid.FriendlyName}}}},
                          @{{Name='KeySize'; Expression={{$_.PublicKey.Key.KeySize}}}},
                          @{{Name='SignatureAlgorithm'; Expression={{$_.SignatureAlgorithm.FriendlyName}}}}
        ";

        pipeline.Commands.AddScript(script);

        var results = pipeline.Invoke();

        var certificates = new List<Domain.Certificates.Certificate>();
        var bindings = new List<CertificateBinding>();

        foreach (var properties in results.Select(result => result.Properties))
        {
            try
            {
                var thumbprint = properties["Thumbprint"]?.Value?.ToString() ?? string.Empty;
                thumbprint = CertificateNormalizer.NormalizeThumbprint(thumbprint);

                var subject = properties["Subject"]?.Value?.ToString() ?? string.Empty;
                var issuer = properties["Issuer"]?.Value?.ToString() ?? string.Empty;

                // Parse dates
                var notBefore = ParseDateTime(
                    properties["NotBefore"]?.Value?.ToString(),
                    DateTime.UtcNow);
                var notAfter = ParseDateTime(
                    properties["NotAfter"]?.Value?.ToString(),
                    DateTime.UtcNow.AddYears(1));

                var hasPrivateKey = bool.Parse(
                    properties["HasPrivateKey"]?.Value?.ToString() ?? "false");

                var serialNumber = properties["SerialNumber"]?.Value?.ToString() ?? string.Empty;
                var keyAlgorithm = properties["KeyAlgorithm"]?.Value?.ToString() ?? "Unknown";
                var keySize = int.TryParse(
                    properties["KeySize"]?.Value?.ToString(),
                    NumberStyles.Integer,
                    CultureInfo.InvariantCulture,
                    out var parsedKeySize)
                    ? parsedKeySize
                    : 0;
                var signatureAlgorithm = properties["SignatureAlgorithm"]?.Value?.ToString() ?? "Unknown";

                // Parse SANs from extension output
                var sanRaw = properties["SANs"]?.Value?.ToString() ?? string.Empty;
                var sans = ParseSubjectAlternativeNames(sanRaw);

                var isSelfSigned = string.Equals(subject, issuer, StringComparison.OrdinalIgnoreCase);

                // Create domain certificate using factory
                var certificate = Domain.Certificates.Certificate.Create(
                    thumbprint: thumbprint,
                    subject: subject,
                    issuer: issuer,
                    validFrom: new DateTimeOffset(notBefore),
                    validTo: new DateTimeOffset(notAfter),
                    sans: sans,
                    hasPrivateKey: hasPrivateKey,
                    isSelfSigned: isSelfSigned,
                    keyAlgorithm: keyAlgorithm,
                    keySize: keySize,
                    signatureAlgorithm: signatureAlgorithm,
                    serialNumber: serialNumber);

                certificates.Add(certificate);

                // Create binding metadata
                var binding = new CertificateBinding
                {
                    Thumbprint = thumbprint,
                    SourceType = "OS",
                    PathLocation = storePath,
                    BindingContext = null
                };

                bindings.Add(binding);
            }
            catch (FormatException ex)
            {
                _logger.LogWarning(
                    ex,
                    "Failed to parse certificate data from {Store} on {Target}",
                    storePath,
                    targetIdentifier);
                // Continue with next certificate
            }
            catch (ArgumentException ex)
            {
                _logger.LogWarning(
                    ex,
                    "Invalid certificate data from {Store} on {Target}",
                    storePath,
                    targetIdentifier);
                // Continue with next certificate
            }
        }

        return (certificates.ToArray(), bindings.ToArray());
    }

    /// <summary>
    /// Parses a datetime string returned from PowerShell, with fallback to provided default.
    /// </summary>
    private static DateTime ParseDateTime(string? value, DateTime defaultValue)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return DateTime.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal | DateTimeStyles.AllowWhiteSpaces,
            out var parsed)
            ? parsed
            : defaultValue;
    }

    /// <summary>
    /// Extracts Subject Alternative Names from the extension format output.
    /// Format is typically "DNS Name=example.com, DNS Name=*.example.com" etc.
    /// </summary>
    private static string[] ParseSubjectAlternativeNames(string? sanRaw)
    {
        if (string.IsNullOrWhiteSpace(sanRaw))
        {
            return Array.Empty<string>();
        }

        var sans = new List<string>();

        // Split by comma and extract the value after '='
        var parts = sanRaw.Split(SanSeparators, StringSplitOptions.RemoveEmptyEntries);

        foreach (var part in parts)
        {
            var trimmed = part.Trim();
            var eqIndex = trimmed.AsSpan().IndexOf('=');

            if (eqIndex > 0 && eqIndex < trimmed.Length - 1)
            {
                var san = trimmed[(eqIndex + 1)..].Trim();
                if (!string.IsNullOrWhiteSpace(san))
                {
                    sans.Add(san);
                }
            }
        }

        return sans.ToArray();
    }
}

public sealed class WinRmCollectorSettings
{
    public WinRmCollectorSettings(
        int maxConcurrency,
        TimeSpan timeout,
        bool useSsl,
        bool skipCertificateAuthorityValidation,
        bool skipCommonNameValidation,
        string serviceAccountUsername,
        string serviceAccountPasswordSecretName)
    {
        if (string.IsNullOrWhiteSpace(serviceAccountUsername))
        {
            throw new ArgumentException("Service account username is required.", nameof(serviceAccountUsername));
        }

        if (string.IsNullOrWhiteSpace(serviceAccountPasswordSecretName))
        {
            throw new ArgumentException("Service account password secret name is required.",
                nameof(serviceAccountPasswordSecretName));
        }

        MaxConcurrency = maxConcurrency;
        Timeout = timeout;
        UseSsl = useSsl;
        SkipCertificateAuthorityValidation = skipCertificateAuthorityValidation;
        SkipCommonNameValidation = skipCommonNameValidation;
        ServiceAccountUsername = serviceAccountUsername;
        ServiceAccountPasswordSecretName = serviceAccountPasswordSecretName;
    }

    public int MaxConcurrency { get; }

    public TimeSpan Timeout { get; }

    public bool UseSsl { get; }

    public bool SkipCertificateAuthorityValidation { get; }

    public bool SkipCommonNameValidation { get; }

    public string ServiceAccountUsername { get; }

    public string ServiceAccountPasswordSecretName { get; }
}

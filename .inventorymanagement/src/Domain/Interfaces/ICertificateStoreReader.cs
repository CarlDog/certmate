namespace Domain.Interfaces;

using Certificates;
using System.Diagnostics.CodeAnalysis;

/// <summary>
/// Port for harvesting certificates and returning both canonical certs and binding metadata.
/// </summary>
public interface ICertificateStoreReader
{
    Task<CertificateCollection> CollectAsync(string targetIdentifier, CancellationToken ct);
}

/// <summary>
/// Intermediate binding metadata DTO (without MachineId).
/// Used by collectors to describe where a certificate was found.
/// The persistence layer combines this with Machine data to create MachineCertificate objects.
/// </summary>
public sealed class CertificateBinding
{
    public required string Thumbprint { get; init; }
    public required string SourceType { get; init; } // OS, IIS, F5, Repository
    public required string PathLocation { get; init; }
    public string? BindingContext { get; init; }
}

[SuppressMessage("Naming", "CA1711:Identifiers should not have incorrect suffix",
    Justification = "Domain language relies on CertificateCollection result DTO")]
public sealed class CertificateCollection
{
    public required string TargetIdentifier { get; init; }
    public required IReadOnlyCollection<Certificate> Certificates { get; init; }
    public required IReadOnlyCollection<CertificateBinding> Bindings { get; init; }
    public DateTimeOffset CollectedAt { get; init; } = DateTimeOffset.UtcNow;
    public bool IsSuccess { get; init; } = true;
    public string? ErrorMessage { get; init; }

    public static CertificateCollection Failed(string target, string? error, DateTimeOffset? collectedAt = null) =>
        new()
        {
            TargetIdentifier = target,
            Certificates = Array.Empty<Certificate>(),
            Bindings = Array.Empty<CertificateBinding>(),
            CollectedAt = collectedAt ?? DateTimeOffset.UtcNow,
            IsSuccess = false,
            ErrorMessage = error
        };
}

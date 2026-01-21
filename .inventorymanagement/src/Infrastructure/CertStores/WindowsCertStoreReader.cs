namespace Infrastructure.CertStores;

using Domain.Certificates;
using Domain.Interfaces;

/// <summary>
/// Adapter for reading certificates from Windows certificate stores (LocalMachine).
/// </summary>
public sealed class WindowsCertStoreReader : ICertificateStoreReader
{
    public Task<CertificateCollection> CollectAsync(string targetIdentifier, CancellationToken ct)
    {
        // Phase 1 placeholder.
        // Stage 2 backlog item: implement WinRM-based remote store enumeration.
        var result = new CertificateCollection
        {
            TargetIdentifier = targetIdentifier,
            Certificates = Array.Empty<Certificate>(),
            Bindings = Array.Empty<CertificateBinding>()
        };
        return Task.FromResult(result);
    }
}

namespace Infrastructure.CertStores;

using Domain.Certificates;

/// <summary>
/// Adapter for reading certificates from user profile stores (HKU).
/// Optional - disabled by default.
/// </summary>
public static class UserProfileCertStoreReader
{
    public static Task<IReadOnlyCollection<Certificate>> GetUserCertificatesAsync(CancellationToken ct)
    {
        // Access user profile certificate stores via registry
        throw new NotImplementedException();
    }
}

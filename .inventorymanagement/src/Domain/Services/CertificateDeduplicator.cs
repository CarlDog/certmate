namespace Domain.Services;

using Certificates;

/// <summary>
/// Deduplicates certificates by thumbprint selecting the first encountered instance.
/// </summary>
public static class CertificateDeduplicator
{
    public static IReadOnlyCollection<Certificate> Deduplicate(IEnumerable<Certificate> certificates)
    {
        ArgumentNullException.ThrowIfNull(certificates);
        var map = new Dictionary<string, Certificate>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in certificates)
        {
            var key = c.Thumbprint.Value;
            map.TryAdd(key, c);
        }

        return map.Values.ToList();
    }
}

namespace Domain.Services;

using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Certificates;

/// <summary>
/// Helper methods for normalizing certificate metadata (thumbprints, SANs, self-signed detection).
/// </summary>
public static class CertificateNormalizer
{
    private const string SubjectAlternativeNameOid = "2.5.29.17";
    private const string DnsNamePrefix = "DNS Name=";
    private static readonly char[] NewLineSeparators = ['\r', '\n'];

    public static string NormalizeThumbprint(string rawThumbprint)
    {
        return Thumbprint.Create(rawThumbprint).Value;
    }

    public static IReadOnlyList<string> ExtractSubjectAlternativeNames(X509Certificate2 certificate)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        var sanExtension = certificate.Extensions
            .Cast<X509Extension?>()
            .FirstOrDefault(ext => ext?.Oid?.Value == SubjectAlternativeNameOid);

        if (sanExtension is null)
        {
            return Array.Empty<string>();
        }

        var formatted = new AsnEncodedData(sanExtension.Oid, sanExtension.RawData).Format(multiLine: true);
        var entries = formatted
            .Split(NewLineSeparators, StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .Where(line => line.StartsWith(DnsNamePrefix, StringComparison.OrdinalIgnoreCase))
            .Select(line => line[DnsNamePrefix.Length..].Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        return entries;
    }

    public static bool IsSelfSigned(string subject, string issuer)
    {
        if (string.IsNullOrWhiteSpace(subject) || string.IsNullOrWhiteSpace(issuer))
        {
            return false;
        }

        return string.Equals(subject.Trim(), issuer.Trim(), StringComparison.OrdinalIgnoreCase);
    }
}

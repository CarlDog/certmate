namespace Domain.Certificates;

/// <summary>
/// Canonical certificate entity (one per unique thumbprint globally).
/// Immutable after construction except for LastUpdated operations handled externally.
/// </summary>
public sealed class Certificate
{
    public Thumbprint Thumbprint { get; }
    public string Subject { get; }
    public string Issuer { get; }
    public DateTimeOffset ValidFrom { get; }
    public DateTimeOffset ValidTo { get; }
    public IReadOnlyList<string> SubjectAlternativeNames { get; }
    public bool HasPrivateKey { get; }
    public bool IsSelfSigned { get; }
    public string KeyAlgorithm { get; }
    public int KeySize { get; }
    public string SignatureAlgorithm { get; }
    public string SerialNumber { get; }

    private Certificate(
        Thumbprint thumbprint,
        string subject,
        string issuer,
        DateTimeOffset validFrom,
        DateTimeOffset validTo,
        IReadOnlyList<string> sans,
        bool hasPrivateKey,
        bool isSelfSigned,
        string keyAlgorithm,
        int keySize,
        string signatureAlgorithm,
        string serialNumber)
    {
        Thumbprint = thumbprint;
        Subject = subject;
        Issuer = issuer;
        ValidFrom = validFrom;
        ValidTo = validTo;
        SubjectAlternativeNames = sans;
        HasPrivateKey = hasPrivateKey;
        IsSelfSigned = isSelfSigned;
        KeyAlgorithm = keyAlgorithm;
        KeySize = keySize;
        SignatureAlgorithm = signatureAlgorithm;
        SerialNumber = serialNumber;
    }

    public static Certificate Create(
        string thumbprint,
        string subject,
        string issuer,
        DateTimeOffset validFrom,
        DateTimeOffset validTo,
        IEnumerable<string>? sans,
        bool hasPrivateKey,
        bool isSelfSigned,
        string keyAlgorithm,
        int keySize,
        string signatureAlgorithm,
        string serialNumber)
    {
        if (string.IsNullOrWhiteSpace(subject))
        {
            throw new ArgumentException("Subject cannot be empty", nameof(subject));
        }

        if (string.IsNullOrWhiteSpace(issuer))
        {
            throw new ArgumentException("Issuer cannot be empty", nameof(issuer));
        }

        if (validTo <= validFrom)
        {
            throw new ArgumentException("ValidTo must be after ValidFrom", nameof(validTo));
        }

        if (keySize <= 0)
        {
            throw new ArgumentException("KeySize must be positive", nameof(keySize));
        }

        if (string.IsNullOrWhiteSpace(keyAlgorithm))
        {
            throw new ArgumentException("KeyAlgorithm cannot be empty", nameof(keyAlgorithm));
        }

        if (string.IsNullOrWhiteSpace(signatureAlgorithm))
        {
            throw new ArgumentException("SignatureAlgorithm cannot be empty", nameof(signatureAlgorithm));
        }

        if (string.IsNullOrWhiteSpace(serialNumber))
        {
            throw new ArgumentException("SerialNumber cannot be empty", nameof(serialNumber));
        }

        var sanList = (sans ?? Array.Empty<string>()).Select(s => s.Trim()).Where(s => s.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        // Wildcard rule: if Subject contains '*' ensure at least one SAN
        if (SubjectContainsWildcard(subject) && sanList.Count == 0)
        {
            throw new ArgumentException("Wildcard subject requires at least one SAN entry", nameof(sans));
        }

        var thumb = Thumbprint.Create(thumbprint);

        return new Certificate(thumb, subject.Trim(), issuer.Trim(), validFrom, validTo, sanList, hasPrivateKey,
            isSelfSigned, keyAlgorithm.Trim(), keySize, signatureAlgorithm.Trim(), serialNumber.Trim());
    }

    public int DaysUntilExpiry(DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.UtcNow;
        return (int)Math.Floor((ValidTo - reference).TotalDays);
    }

    private static bool SubjectContainsWildcard(string subject) => subject.Contains('*', StringComparison.Ordinal);
}

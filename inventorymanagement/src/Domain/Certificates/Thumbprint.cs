namespace Domain.Certificates;

/// <summary>
/// Value object representing a certificate thumbprint (SHA-1 40 hex chars or SHA-256 64 hex chars).
/// Normalization: removes ':' and whitespace, uppercases, validates hex length.
/// </summary>
public readonly record struct Thumbprint
{
    public string Value { get; }

    private Thumbprint(string value)
    {
        Value = value;
    }

    public static Thumbprint Create(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new ArgumentException("Thumbprint cannot be null or empty", nameof(raw));
        }

        // Remove colons and whitespace
        var cleaned = raw
            .Replace(":", string.Empty, StringComparison.Ordinal)
            .Replace(" ", string.Empty, StringComparison.Ordinal)
            .Trim();
        cleaned = cleaned.ToUpperInvariant();

        if (cleaned.Length is not 40 and not 64)
        {
            throw new ArgumentException(
                "Thumbprint must be 40 (SHA-1) or 64 (SHA-256) hex characters after normalization", nameof(raw));
        }

        // Validate hex
        foreach (var c in cleaned)
        {
            var isHex = c is >= '0' and <= '9' or >= 'A' and <= 'F';
            if (!isHex)
            {
                throw new ArgumentException("Thumbprint contains non-hex characters", nameof(raw));
            }
        }

        return new Thumbprint(cleaned);
    }

    public override string ToString() => Value;
}

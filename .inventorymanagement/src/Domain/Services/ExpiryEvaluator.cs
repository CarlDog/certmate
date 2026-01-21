namespace Domain.Services;

using Certificates;

public enum ExpiryStatus
{
    Expired,
    Critical,
    Warning,
    Valid
}

/// <summary>
/// Evaluates expiry classification based on remaining days.
/// </summary>
public static class ExpiryEvaluator
{
    public static ExpiryStatus Evaluate(Certificate certificate, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        var reference = now ?? DateTimeOffset.UtcNow;
        if (certificate.ValidTo <= reference)
        {
            return ExpiryStatus.Expired;
        }

        var days = (certificate.ValidTo - reference).TotalDays;
        if (days <= 30)
        {
            return ExpiryStatus.Critical;
        }

        if (days <= 90)
        {
            return ExpiryStatus.Warning;
        }

        return ExpiryStatus.Valid;
    }

    public static bool IsExpiringSoon(Certificate certificate, int daysThreshold, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        var reference = now ?? DateTimeOffset.UtcNow;
        if (certificate.ValidTo <= reference)
        {
            return true; // treat expired as expiring
        }

        var days = (certificate.ValidTo - reference).TotalDays;
        return days <= daysThreshold;
    }
}

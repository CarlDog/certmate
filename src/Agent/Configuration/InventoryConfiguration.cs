namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Configuration model for inventory and digest settings.
/// </summary>
internal sealed class InventoryConfiguration
{
    [Required] public WeeklyDigestSettings WeeklyDigest { get; set; } = new();
}

internal sealed class WeeklyDigestSettings
{
    public bool Enabled { get; set; }

    public DayOfWeek DayOfWeek { get; set; } = DayOfWeek.Monday;

    [Range(0, 23)] public int HourUtc { get; set; } = 8;

    public string? WebhookUrlSecretName { get; set; }

    public IReadOnlyCollection<int> ExpirationThresholds { get; set; } = new[] { 30, 60, 90 };
}

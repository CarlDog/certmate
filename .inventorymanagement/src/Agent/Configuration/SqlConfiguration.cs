namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Configuration model for SQL connection settings.
/// </summary>
internal sealed class SqlConfiguration
{
    [Required] public string ConnectionString { get; set; } = string.Empty;

    [Range(5, 600)] public int CommandTimeoutSeconds { get; set; } = 30;

    public bool EnableRetryOnFailure { get; set; } = true;

    [Range(0, 10)] public int MaxRetryCount { get; set; } = 3;

    [Range(1, 120)] public int MaxRetryDelaySeconds { get; set; } = 10;
}

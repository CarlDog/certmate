namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Configuration model for F5 settings.
/// </summary>
internal sealed class F5Configuration
{
    [Range(1, 10)]
    public int RequestsPerSecond { get; set; } = 5;

    [Range(5, 120)]
    public int TimeoutSeconds { get; set; } = 30;

    [Range(0, 5)]
    public int MaxRetries { get; set; } = 3;

    public ICollection<F5DeviceConfiguration> Devices { get; set; } = new List<F5DeviceConfiguration>();
}

internal sealed class F5DeviceConfiguration
{
    [Required]
    public string Name { get; set; } = string.Empty;

    [Required]
    public Uri BaseUrl { get; set; } = new("https://f5-device.example.com");

    [Required]
    public string Username { get; set; } = string.Empty;

    [Required]
    public string PasswordSecretName { get; set; } = string.Empty;

    public string Partition { get; set; } = "Common";

    public bool Enabled { get; set; } = true;
}

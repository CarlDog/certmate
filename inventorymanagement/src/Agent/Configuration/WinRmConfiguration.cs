namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Configuration model for WinRM settings.
/// </summary>
internal sealed class WinRmConfiguration
{
    [Range(1, 32)] public int MaxConcurrency { get; set; } = 10;

    [Range(10, 600)] public int TimeoutSeconds { get; set; } = 60;

    public bool UseSsl { get; set; } = true;

    public bool SkipCaCheck { get; set; }

    public bool SkipCnCheck { get; set; }

    [Required] public WinRmServiceAccountConfiguration ServiceAccount { get; set; } = new();
}

/// <summary>
/// Service account credentials sourced from Azure Key Vault/user secrets.
/// </summary>
internal sealed class WinRmServiceAccountConfiguration
{
    [Required] public string Username { get; set; } = string.Empty;

    [Required] public string PasswordSecretName { get; set; } = string.Empty;
}

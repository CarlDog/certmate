namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Azure Key Vault configuration used to hydrate secrets.
/// </summary>
internal sealed class AzureKeyVaultConfiguration
{
    public bool Enabled { get; set; }

    [Url]
    public string? VaultUri { get; set; }

    public bool UseManagedIdentity { get; set; } = true;

    public string? TenantId { get; set; }

    public string? ClientId { get; set; }

    /// <summary>
    /// Plaintext client secret pulled from user secrets (never committed).
    /// </summary>
    public string? ClientSecret { get; set; }
}

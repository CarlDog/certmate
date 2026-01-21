using Agent;
using Agent.Configuration;
using Azure.Core;
using Azure.Identity;
using Serilog;

var builder = Host.CreateApplicationBuilder(args);

ConfigureKeyVault(builder);

builder.Logging.ClearProviders();
builder.Services.AddSerilog((services, loggerConfiguration) =>
{
    loggerConfiguration
        .ReadFrom.Configuration(builder.Configuration)
        .ReadFrom.Services(services)
        .Enrich.FromLogContext()
        .Enrich.WithProperty("Application", "InventoryManagement.Agent");
});

builder.Services
    .AddInventoryServices(builder.Configuration)
    .AddHostedService<Worker>();

var host = builder.Build();
await host.RunAsync().ConfigureAwait(false);

static void ConfigureKeyVault(HostApplicationBuilder builder)
{
    var keyVaultOptions = builder.Configuration.GetSection("AzureKeyVault").Get<AzureKeyVaultConfiguration>();

    if (keyVaultOptions is not { Enabled: true })
    {
        return;
    }

    if (!Uri.TryCreate(keyVaultOptions.VaultUri, UriKind.Absolute, out var vaultUri))
    {
        throw new InvalidOperationException("Azure Key Vault is enabled but VaultUri is not a valid absolute URI.");
    }

    TokenCredential credential;
    if (keyVaultOptions.UseManagedIdentity)
    {
        credential = new DefaultAzureCredential();
    }
    else
    {
        credential = BuildClientSecretCredential(keyVaultOptions);
    }

    builder.Configuration.AddAzureKeyVault(vaultUri, credential);
}

static ClientSecretCredential BuildClientSecretCredential(AzureKeyVaultConfiguration options)
{
    if (string.IsNullOrWhiteSpace(options.TenantId) ||
        string.IsNullOrWhiteSpace(options.ClientId) ||
        string.IsNullOrWhiteSpace(options.ClientSecret))
    {
        throw new InvalidOperationException("Azure Key Vault client secret configuration is incomplete.");
    }

    return new ClientSecretCredential(options.TenantId, options.ClientId, options.ClientSecret);
}

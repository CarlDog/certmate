namespace Agent.Configuration;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Domain.Interfaces;
using Infrastructure.CertStores;
using Infrastructure.Persistence;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

/// <summary>
/// DI composition root.
/// Registers all services, ports, and adapters.
/// </summary>
internal static class ServiceRegistration
{
    public static IServiceCollection AddInventoryServices(this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        services
            .AddOptions<SqlConfiguration>()
            .Bind(configuration.GetSection("Sql"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<WinRmConfiguration>()
            .Bind(configuration.GetSection("WinRM"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<F5Configuration>()
            .Bind(configuration.GetSection("F5"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<InventoryConfiguration>()
            .Bind(configuration.GetSection("Inventory"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<HarvestConfiguration>()
            .Bind(configuration.GetSection("Harvest"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<AzureKeyVaultConfiguration>()
            .Bind(configuration.GetSection("AzureKeyVault"))
            .ValidateDataAnnotations();

        services.AddSingleton(provider => BuildTargetServerOptions(provider.GetRequiredService<IConfiguration>()));

        services.AddSingleton<ICertificateStoreReader>(provider =>
        {
            var winRm = provider.GetRequiredService<IOptions<WinRmConfiguration>>().Value;
            var logger = provider.GetRequiredService<ILogger<RemoteWinRmCertCollector>>();

            var settings = new WinRmCollectorSettings(
                winRm.MaxConcurrency,
                TimeSpan.FromSeconds(winRm.TimeoutSeconds),
                winRm.UseSsl,
                winRm.SkipCaCheck,
                winRm.SkipCnCheck,
                winRm.ServiceAccount.Username,
                winRm.ServiceAccount.PasswordSecretName);

            return new RemoteWinRmCertCollector(settings, logger);
        });

        services.AddSingleton<ICertificateStoreReader, WindowsCertStoreReader>();

        services.AddSingleton<IIngestionWriter>(provider =>
        {
            var sql = provider.GetRequiredService<IOptions<SqlConfiguration>>().Value;
            var logger = provider.GetRequiredService<ILogger<SqlServerPersistence>>();

            return new SqlServerPersistence(
                sql.ConnectionString,
                TimeSpan.FromSeconds(sql.CommandTimeoutSeconds),
                sql.EnableRetryOnFailure,
                sql.MaxRetryCount,
                TimeSpan.FromSeconds(sql.MaxRetryDelaySeconds),
                logger);
        });

        // Register domain services
        // Register application use cases
        // Register infrastructure adapters
        return services;
    }

    private static IOptions<TargetServerOptions> BuildTargetServerOptions(IConfiguration configuration)
    {
        var configured = configuration.GetSection("TargetServers").Get<string[]>() ?? Array.Empty<string>();

        return Options.Create(new TargetServerOptions
        {
            Servers = configured
        });
    }
}

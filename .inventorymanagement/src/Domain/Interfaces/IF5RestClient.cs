namespace Domain.Interfaces;

/// <summary>
/// Port for F5 REST API interactions.
/// </summary>
public interface IF5RestClient
{
    Task<T> GetAsync<T>(string endpoint, CancellationToken ct);
    // Token auth, capability negotiation, rate limiting handled by adapter
}

namespace Infrastructure.F5;

using Domain.Interfaces;

/// <summary>
/// F5 REST API client with token authentication and rate limiting.
/// BIG-IP 17.1.3 (Build 0.0.11).
/// </summary>
public sealed class F5RestClient : IF5RestClient
{
    public Task<T> GetAsync<T>(string endpoint, CancellationToken ct)
    {
        // Token auth, BIG-IP 17.1.3 REST API, Polly rate limiting (5 req/s)
        throw new NotImplementedException();
    }
}

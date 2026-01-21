namespace Infrastructure.Retry;

using Polly;

/// <summary>
/// Polly retry and rate-limiting policy factory.
/// </summary>
public static class PolicyFactory
{
    public static IAsyncPolicy CreateF5RateLimitPolicy(int requestsPerSecond = 5)
    {
        // Token bucket limiter for F5 at 5 req/s with burst=5
        throw new NotImplementedException();
    }

    public static IAsyncPolicy CreateWinRmRetryPolicy()
    {
        // Exponential backoff for transient WinRM failures
        throw new NotImplementedException();
    }
}

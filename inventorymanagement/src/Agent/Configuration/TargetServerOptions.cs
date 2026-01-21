namespace Agent.Configuration;

/// <summary>
/// Manual list of servers targeted during Phase 1 harvests.
/// </summary>
internal sealed class TargetServerOptions
{
    public IReadOnlyCollection<string> Servers { get; init; } = Array.Empty<string>();
}

namespace Domain.Interfaces;

/// <summary>
/// Port for time provider (testing seam).
/// </summary>
public interface IClock
{
    DateTimeOffset UtcNow { get; }
}

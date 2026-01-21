namespace Domain.Interfaces;

/// <summary>
/// Port for sending Teams notifications.
/// </summary>
public interface ITeamsNotifier
{
    Task SendWeeklyDigestAsync(string message, CancellationToken ct);
}

namespace Infrastructure.Messaging;

using Domain.Interfaces;

/// <summary>
/// Teams webhook publisher for weekly digest notifications.
/// </summary>
public sealed class TeamsWebhookPublisher : ITeamsNotifier
{
    public Task SendWeeklyDigestAsync(string message, CancellationToken ct)
    {
        // POST to Teams webhook URL
        throw new NotImplementedException();
    }
}

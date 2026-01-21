namespace Application.Commands;

/// <summary>
/// Inbound port: Command to trigger certificate collection.
/// </summary>
public interface ICertificateCollectionCommand
{
    Task ExecuteAsync(CancellationToken ct);
}

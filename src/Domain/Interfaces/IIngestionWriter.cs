namespace Domain.Interfaces;

using Certificates;
using Machines;

/// <summary>
/// Port for persisting harvest results (machine + certificates + bindings).
/// </summary>
public interface IIngestionWriter
{
    Task<IngestionOutcome> PersistAsync(
        Machine machine,
        IEnumerable<Certificate> certificates,
        IEnumerable<MachineCertificate> bindings,
        CancellationToken ct);
}

public sealed class IngestionOutcome
{
    public int CertificatesInserted { get; init; }
    public int CertificatesUpdated { get; init; }
    public int BindingsInserted { get; init; }
    public int BindingsUpdated { get; init; }
    public IReadOnlyList<string> Errors { get; init; } = Array.Empty<string>();
    public bool IsSuccess => Errors.Count == 0;
}

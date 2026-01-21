namespace Application.UseCases;

using Domain.Interfaces;

/// <summary>
/// Use case: Collect certificates from local machine stores.
/// </summary>
public static class LocalCertificates
{
    public static Task<IngestionOutcome> ExecuteAsync(
        ICertificateStoreReader storeReader,
        IIngestionWriter writer,
        CancellationToken ct)
    {
        // Read certs, normalize, deduplicate, persist
        throw new NotImplementedException();
    }
}

namespace Domain.Machines;

using System.Text.Json;
using Certificates;

/// <summary>
/// Represents a binding of a certificate to a machine with location and source context.
/// </summary>
public sealed class MachineCertificate
{
    public int MachineId { get; }
    public Thumbprint Thumbprint { get; }
    public string SourceType { get; }
    public string PathLocation { get; }
    public string? BindingContextJson { get; }
    public DateTimeOffset DateDiscovered { get; }
    public DateTimeOffset LastVerified { get; private set; }
    public DateTimeOffset? DeletedAt { get; private set; }

    private MachineCertificate(int machineId,
        Thumbprint thumbprint,
        string sourceType,
        string pathLocation,
        string? bindingContextJson,
        DateTimeOffset dateDiscovered,
        DateTimeOffset lastVerified,
        DateTimeOffset? deletedAt)
    {
        MachineId = machineId;
        Thumbprint = thumbprint;
        SourceType = sourceType;
        PathLocation = pathLocation;
        BindingContextJson = bindingContextJson;
        DateDiscovered = dateDiscovered;
        LastVerified = lastVerified;
        DeletedAt = deletedAt;
    }

    private static readonly string[] AllowedSourceTypes = ["OS", "IIS", "F5", "Repository"];

    public static MachineCertificate Create(int machineId,
        string thumbprint,
        string sourceType,
        string pathLocation,
        string? bindingContextJson,
        DateTimeOffset when)
    {
        if (machineId <= 0)
        {
            throw new ArgumentException("MachineId must be positive", nameof(machineId));
        }

        if (string.IsNullOrWhiteSpace(sourceType))
        {
            throw new ArgumentException("SourceType required", nameof(sourceType));
        }

        sourceType = sourceType.Trim();
        if (!AllowedSourceTypes.Contains(sourceType))
        {
            throw new ArgumentException("SourceType not supported", nameof(sourceType));
        }

        if (string.IsNullOrWhiteSpace(pathLocation))
        {
            throw new ArgumentException("PathLocation required", nameof(pathLocation));
        }

        pathLocation = pathLocation.Trim();

        var normalizedBindingContext = NormalizeBindingContext(bindingContextJson);
        var t = Thumbprint.Create(thumbprint);
        return new MachineCertificate(machineId, t, sourceType, pathLocation, normalizedBindingContext, when, when,
            null);
    }

    public void Verify(DateTimeOffset when) => LastVerified = when >= DateDiscovered ? when : LastVerified;
    public void MarkDeleted(DateTimeOffset when) => DeletedAt = when >= DateDiscovered ? when : DeletedAt;
    public void Recover() => DeletedAt = null;

    private static string? NormalizeBindingContext(string? bindingContextJson)
    {
        if (string.IsNullOrWhiteSpace(bindingContextJson))
        {
            return null;
        }

        var trimmed = bindingContextJson.Trim();
        try
        {
            using var _ = JsonDocument.Parse(trimmed);
        }
        catch (JsonException ex)
        {
            throw new ArgumentException("BindingContextJson must be valid JSON", nameof(bindingContextJson), ex);
        }

        return trimmed;
    }
}

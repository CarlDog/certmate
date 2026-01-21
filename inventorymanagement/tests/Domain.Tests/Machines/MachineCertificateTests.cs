using Domain.Machines;

namespace Domain.Tests.Machines;

public sealed class MachineCertificateTests
{
    [Fact]
    public void Create_WithInvalidMachineId_Throws()
    {
        Assert.Throws<ArgumentException>(() =>
            MachineCertificate.Create(0, new string('A', 40), "OS", "LocalMachine/My", null, DateTimeOffset.UtcNow));
    }

    [Theory]
    [MemberData(nameof(GetInvalidInputData))]
    public void Create_WithInvalidInputs_Throws(int machineId, string thumbprint, string sourceType,
        string pathLocation)
    {
        Assert.Throws<ArgumentException>(() =>
            MachineCertificate.Create(machineId, thumbprint, sourceType, pathLocation, null, DateTimeOffset.UtcNow));
    }

    [Fact]
    public void Create_WithInvalidJson_Throws()
    {
        Assert.Throws<ArgumentException>(() =>
            MachineCertificate.Create(1, new string('A', 40), "OS", "LocalMachine/My", "not-json",
                DateTimeOffset.UtcNow));
    }

    [Fact]
    public void Verify_UpdatesLastVerified()
    {
        var when = DateTimeOffset.UtcNow;
        var binding = MachineCertificate.Create(1, new string('A', 40), "OS", "LocalMachine/My", null, when);
        var later = when.AddMinutes(5);

        binding.Verify(later);

        Assert.Equal(later, binding.LastVerified);
    }

    [Fact]
    public void MarkDeleted_SetsDeletedAt()
    {
        var when = DateTimeOffset.UtcNow;
        var binding = MachineCertificate.Create(1, new string('A', 40), "OS", "LocalMachine/My", null, when);
        var later = when.AddMinutes(5);

        binding.MarkDeleted(later);

        Assert.Equal(later, binding.DeletedAt);

        binding.Recover();
        Assert.Null(binding.DeletedAt);
    }

    public static IEnumerable<object?[]> GetInvalidInputData => new List<object?[]>
    {
        new object?[] { 1, string.Empty, "OS", "LocalMachine/My" },
        new object?[] { 1, new string('A', 40), string.Empty, "LocalMachine/My" },
        new object?[] { 1, new string('A', 40), "FTP", "LocalMachine/My" },
        new object?[] { 1, new string('A', 40), "OS", " " }
    };
}

using Domain.Machines;

namespace Domain.Tests.Machines;

public sealed class MachineTests
{
    [Fact]
    public void Create_WithEmptyHostname_Throws()
    {
        Assert.Throws<ArgumentException>(() => Machine.Create(" ", null, "DEV", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, "Reachable"));
    }

    [Fact]
    public void Create_WithInvalidEnvironment_Throws()
    {
        Assert.Throws<ArgumentException>(() => Machine.Create("server01", null, "INVALID", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, "Reachable"));
    }

    [Fact]
    public void Create_WithLastSeenBeforeFirstSeen_Throws()
    {
        var first = DateTimeOffset.UtcNow;
        var last = first.AddMinutes(-5);
        Assert.Throws<ArgumentException>(() => Machine.Create("server01", null, "DEV", first, last, "Reachable"));
    }

    [Fact]
    public void UpdateSeen_AdvancesTimestamp()
    {
        var first = DateTimeOffset.UtcNow;
        var machine = Machine.Create("server01", null, "DEV", first, first, "Reachable");
        var later = first.AddMinutes(10);

        machine.UpdateSeen(later);

        Assert.Equal(later, machine.LastSeen);
        Assert.True(machine.IsActive);
    }

    [Fact]
    public void SetWinRmStatus_TrimsAndIgnoresEmpty()
    {
        var now = DateTimeOffset.UtcNow;
        var machine = Machine.Create("server01", null, "DEV", now, now, "Unknown");

        machine.SetWinRmStatus("  Reachable  ");
        Assert.Equal("Reachable", machine.WinRmStatus);

        machine.SetWinRmStatus(" ");
        Assert.Equal("Reachable", machine.WinRmStatus);
    }

    [Theory]
    [InlineData("server01-dev.corp.local", "DEV")]
    [InlineData("srv01.test.corp", "TEST")]
    [InlineData("api-prod-01", "PROD")]
    [InlineData("uat-app", "UAT")]
    [InlineData("unknown", "Unknown")]
    public void DetermineEnvironment_ParsesTokens(string input, string expected)
    {
        Assert.Equal(expected, Machine.DetermineEnvironment(input));
    }
}

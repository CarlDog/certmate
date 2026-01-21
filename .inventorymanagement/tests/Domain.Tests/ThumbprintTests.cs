using Domain.Certificates;

namespace Domain.Tests;

public sealed class ThumbprintTests
{
    [Fact]
    public void Create_NormalizesUppercaseAndRemovesColons()
    {
        var raw = "ab:cd:ef:12:34:56:78:90:aa:bb:cc:dd:ee:ff:11:22:33:44:55:66"; // 40 hex with colons
        var tp = Thumbprint.Create(raw);
        Assert.Equal(raw.Replace(":", string.Empty, StringComparison.Ordinal).ToUpperInvariant(), tp.Value);
    }

    [Theory]
    [InlineData("", "Thumbprint cannot be null or empty")]
    [InlineData("XYZ", "Thumbprint must be 40 (SHA-1) or 64 (SHA-256)")] // length fail after cleanup
    public void Create_InvalidInputs_Throws(string input, string expectedStart)
    {
        var ex = Assert.Throws<ArgumentException>(() => Thumbprint.Create(input));
        Assert.StartsWith(expectedStart, ex.Message, StringComparison.Ordinal);
    }
}

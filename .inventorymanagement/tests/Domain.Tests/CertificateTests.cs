using Domain.Certificates;

namespace Domain.Tests;

public sealed class CertificateTests
{
    private static readonly string[] DefaultSans = ["example.com"];

    [Fact]
    public void Create_WildcardWithoutSans_Throws()
    {
        Assert.Throws<ArgumentException>(() => Certificate.Create(
            thumbprint: new string('A', 40),
            subject: "CN=*.example.com",
            issuer: "CN=TestCA",
            validFrom: DateTimeOffset.UtcNow.AddDays(-1),
            validTo: DateTimeOffset.UtcNow.AddDays(10),
            sans: Array.Empty<string>(),
            hasPrivateKey: true,
            isSelfSigned: false,
            keyAlgorithm: "RSA",
            keySize: 2048,
            signatureAlgorithm: "sha256RSA",
            serialNumber: "1234"));
    }

    [Fact]
    public void Create_Valid_Works()
    {
        var cert = Certificate.Create(
            thumbprint: new string('A', 40),
            subject: "CN=example.com",
            issuer: "CN=TestCA",
            validFrom: DateTimeOffset.UtcNow.AddDays(-1),
            validTo: DateTimeOffset.UtcNow.AddDays(365),
            sans: DefaultSans,
            hasPrivateKey: true,
            isSelfSigned: false,
            keyAlgorithm: "RSA",
            keySize: 2048,
            signatureAlgorithm: "sha256RSA",
            serialNumber: "1234");
        Assert.True(cert.DaysUntilExpiry(DateTimeOffset.UtcNow) >= 364);
    }
}

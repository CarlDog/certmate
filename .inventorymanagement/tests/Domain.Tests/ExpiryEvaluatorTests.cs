using Domain.Certificates;
using Domain.Services;

namespace Domain.Tests;

public sealed class ExpiryEvaluatorTests
{
    private static readonly string[] DefaultSans = ["example.com"];

    private static Certificate MakeCert(int days)
    {
        return Certificate.Create(
            thumbprint: new string('B', 40),
            subject: "CN=example.com",
            issuer: "CN=TestCA",
            validFrom: DateTimeOffset.UtcNow.AddDays(-1),
            validTo: DateTimeOffset.UtcNow.AddDays(days),
            sans: DefaultSans,
            hasPrivateKey: true,
            isSelfSigned: false,
            keyAlgorithm: "RSA",
            keySize: 2048,
            signatureAlgorithm: "sha256RSA",
            serialNumber: "1234");
    }

    [Fact]
    public void Evaluate_Expired()
    {
        var cert = MakeCert(-1);
        Assert.Equal(ExpiryStatus.Expired, ExpiryEvaluator.Evaluate(cert, DateTimeOffset.UtcNow));
    }

    [Fact]
    public void Evaluate_Critical()
    {
        var cert = MakeCert(10);
        Assert.Equal(ExpiryStatus.Critical, ExpiryEvaluator.Evaluate(cert, DateTimeOffset.UtcNow));
    }

    [Fact]
    public void Evaluate_Warning()
    {
        var cert = MakeCert(60);
        Assert.Equal(ExpiryStatus.Warning, ExpiryEvaluator.Evaluate(cert, DateTimeOffset.UtcNow));
    }

    [Fact]
    public void Evaluate_Valid()
    {
        var cert = MakeCert(200);
        Assert.Equal(ExpiryStatus.Valid, ExpiryEvaluator.Evaluate(cert, DateTimeOffset.UtcNow));
    }
}

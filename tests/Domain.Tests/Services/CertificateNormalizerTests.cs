using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Domain.Services;

namespace Domain.Tests.Services;

public sealed class CertificateNormalizerTests
{
    [Fact]
    public void NormalizeThumbprint_RemovesDelimitersAndUppercases()
    {
        var segments = Enumerable.Repeat("aa", 20);
        var raw = string.Join(':', segments);

        var normalized = CertificateNormalizer.NormalizeThumbprint(raw);

        Assert.Equal(new string('A', 40), normalized);
    }

    [Fact]
    public void ExtractSubjectAlternativeNames_ReturnsDnsEntries()
    {
        using var certificate = CreateCertificateWithSans("example.com", "api.example.com");

        var sans = CertificateNormalizer.ExtractSubjectAlternativeNames(certificate);

        Assert.Contains("example.com", sans);
        Assert.Contains("api.example.com", sans);
    }

    [Fact]
    public void ExtractSubjectAlternativeNames_NoExtension_ReturnsEmpty()
    {
        using var certificate = CreateCertificateWithSans();

        var sans = CertificateNormalizer.ExtractSubjectAlternativeNames(certificate);

        Assert.Empty(sans);
    }

    [Fact]
    public void IsSelfSigned_ComparesSubjectAndIssuer()
    {
        Assert.True(CertificateNormalizer.IsSelfSigned("CN=Example", "cn=example"));
        Assert.False(CertificateNormalizer.IsSelfSigned("CN=Example", "CN=Different"));
    }

    private static X509Certificate2 CreateCertificateWithSans(params string[] dnsNames)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=unit-test", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        if (dnsNames.Length > 0)
        {
            var sanBuilder = new SubjectAlternativeNameBuilder();
            foreach (var dns in dnsNames)
            {
                sanBuilder.AddDnsName(dns);
            }

            request.CertificateExtensions.Add(sanBuilder.Build());
        }

        return request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
    }
}

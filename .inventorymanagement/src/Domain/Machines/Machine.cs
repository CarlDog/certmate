namespace Domain.Machines;

using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Represents an inventory machine (server). Hostname is the natural key.
/// </summary>
public sealed class Machine
{
    public string Hostname { get; }
    public string? Fqdn { get; }
    public string Environment { get; }
    public DateTimeOffset FirstSeen { get; }
    public DateTimeOffset LastSeen { get; private set; }
    public bool IsActive { get; private set; }
    public string WinRmStatus { get; private set; }

    private Machine(string hostname,
        string? fqdn,
        string environment,
        DateTimeOffset firstSeen,
        DateTimeOffset lastSeen,
        bool isActive,
        string winRmStatus)
    {
        Hostname = hostname;
        Fqdn = fqdn;
        Environment = environment;
        FirstSeen = firstSeen;
        LastSeen = lastSeen;
        IsActive = isActive;
        WinRmStatus = winRmStatus;
    }

    private static readonly string[] AllowedEnvironments = ["DEV", "TEST", "INTG", "UAT", "PROD", "DEMO", "Unknown"];

    private static readonly Dictionary<string, string> EnvironmentTokenMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["DEV"] = "DEV",
        ["DEVELOPMENT"] = "DEV",
        ["TEST"] = "TEST",
        ["QA"] = "TEST",
        ["INT"] = "INTG",
        ["INTG"] = "INTG",
        ["UAT"] = "UAT",
        ["PREPROD"] = "UAT",
        ["PROD"] = "PROD",
        ["PRD"] = "PROD",
        ["DEMO"] = "DEMO"
    };

    private static readonly char[] EnvironmentDelimiters = ['.', '-', '_'];

    public static Machine Create(string hostname, string? fqdn, string environment, DateTimeOffset firstSeen,
        DateTimeOffset lastSeen, string winRmStatus)
    {
        if (string.IsNullOrWhiteSpace(hostname))
        {
            throw new ArgumentException("Hostname cannot be empty", nameof(hostname));
        }

        hostname = hostname.Trim();
        if (fqdn != null)
        {
            fqdn = fqdn.Trim();
        }

        environment = string.IsNullOrWhiteSpace(environment) ? "Unknown" : environment.Trim().ToUpperInvariant();
        if (!AllowedEnvironments.Contains(environment))
        {
            throw new ArgumentException("Environment value not allowed", nameof(environment));
        }

        if (lastSeen < firstSeen)
        {
            throw new ArgumentException("LastSeen must be >= FirstSeen", nameof(lastSeen));
        }

        winRmStatus = string.IsNullOrWhiteSpace(winRmStatus) ? "Unknown" : winRmStatus.Trim();

        return new Machine(hostname, fqdn, environment, firstSeen, lastSeen, true, winRmStatus);
    }

    public void UpdateSeen(DateTimeOffset when)
    {
        if (when < FirstSeen)
        {
            return;
        }

        LastSeen = when;
        IsActive = true;
    }

    public void MarkInactive() => IsActive = false;

    public void SetWinRmStatus(string status) =>
        WinRmStatus = string.IsNullOrWhiteSpace(status) ? WinRmStatus : status.Trim();

    public static string DetermineEnvironment(string? hostnameOrFqdn)
    {
        if (string.IsNullOrWhiteSpace(hostnameOrFqdn))
        {
            return "Unknown";
        }

        var tokens = hostnameOrFqdn
            .Split(EnvironmentDelimiters, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(static token => token.ToUpperInvariant());

        foreach (var token in tokens)
        {
            if (EnvironmentTokenMap.TryGetValue(token, out var mapped))
            {
                return mapped;
            }
        }

        return "Unknown";
    }
}

namespace Agent.Configuration;

using System.ComponentModel.DataAnnotations;

/// <summary>
/// Harvest schedule configuration (Interval + startup delay).
/// </summary>
internal sealed class HarvestConfiguration
{
    [Range(5, 1440)] public int IntervalMinutes { get; set; } = 1440;

    [Range(0, 60)] public int StartupDelayMinutes { get; set; } = 5;

    public bool EnableParallelHarvest { get; set; }
}

using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.App.Services;

// Shapes exchanged with the page. Property names become camelCase JSON.

/// <summary>Process tab state (global tone + orientation).</summary>
public sealed class ProcessDto
{
    public int Method { get; set; }
    public int Flags { get; set; }
    public int Contrast { get; set; }
    public int Brightness { get; set; }
    public int Gamma { get; set; } = 100;
    public int Strength { get; set; } = ToneAdjust.StrengthDefault;
    public int Sharpness { get; set; }
    public int SharpnessMode { get; set; }
    public int Rotation { get; set; }
    public bool Mirror { get; set; }
    public bool Negative { get; set; }
    /// <summary>Show the tone adjustment on the strip view too.</summary>
    public bool PreviewOnStrips { get; set; } = true;

    public ToneSettings Tone => new(Method, Flags, Contrast, Brightness, Gamma, Strength);

    public ProcessSettings ToProcessSettings(bool rotateCw) => new()
    {
        Rotation = Rotation, FlipH = Mirror, Negative = Negative, Tone = Tone,
        Sharpness = Sharpness, SharpnessMode = SharpnessMode, SourceRotateCw = rotateCw,
    };

    public static ProcessDto FromRoll(RollData r) => new()
    {
        Method = r.AdjustMethod, Flags = r.AdjustFlags, Contrast = r.AdjustContrast,
        Brightness = r.AdjustBrightness, Gamma = r.AdjustGamma, Strength = r.AdjustStrength,
        Sharpness = r.Sharpness, SharpnessMode = r.SharpnessMode,
    };

    public void StoreTo(RollData r)
    {
        r.AdjustMethod = Method; r.AdjustFlags = Flags; r.AdjustContrast = Contrast;
        r.AdjustBrightness = Brightness; r.AdjustGamma = Gamma; r.AdjustStrength = Strength;
        r.Sharpness = Sharpness; r.SharpnessMode = SharpnessMode;
    }
}

/// <summary>Export tab state.</summary>
public sealed class ExportDto
{
    public string OutputRoot { get; set; } = "";
    public int NamingMode { get; set; }
    public string Prefix { get; set; } = "";
    public int FileDigits { get; set; } = 5;
    public bool SeparateFolders { get; set; } = true;
    public string ArchiveList { get; set; } = "";
    public int Quality { get; set; } = 100;
    public bool Progressive { get; set; }
    public bool SkipExisting { get; set; }
    public bool AllowPreviewFallback { get; set; }
    public bool LocalTempStage { get; set; }
    public int Workers { get; set; } = 4;
    public int StripCacheLimit { get; set; } = 8;
    /// <summary>"all" or "selected".</summary>
    public string Scope { get; set; } = "all";
    public List<int> Indices { get; set; } = [];

    public NamingOptions ToNaming(string defaultRoot) => new()
    {
        OutputRoot = string.IsNullOrWhiteSpace(OutputRoot) ? defaultRoot : OutputRoot.Trim(),
        Mode = NamingMode, Prefix = Prefix, FileDigits = Math.Clamp(FileDigits, 1, 12),
        SeparateFolders = SeparateFolders, ArchiveList = ArchiveList,
    };

    public ExportOptions ToOptions() => new()
    {
        Quality = Math.Clamp(Quality, 1, 100), Progressive = Progressive, SkipExisting = SkipExisting,
        AllowPreviewFallback = AllowPreviewFallback, LocalTempStage = LocalTempStage,
        Workers = Math.Clamp(Workers, 1, 32), StripCacheLimit = Math.Clamp(StripCacheLimit, 2, 64),
    };
}

public sealed class DetectDto
{
    public int StripFrom { get; set; }
    public int StripTo { get; set; } = -1;
    public int Threshold { get; set; } = 100;
    public int MinWidth { get; set; } = 252;
    public int MinLength { get; set; } = 252;
    public int LeftInset { get; set; }
    public int RightInset { get; set; }
    public bool UseToneSliders { get; set; } = true;
    // Advanced (QuantumScan-style) controls; null = default
    public int MinRun { get; set; }
    public int TouchWidth { get; set; }
    public int TouchLength { get; set; } = -1;   // -1 = roll length / 64 (previous fixed value)
    public int MaxLength { get; set; }
    public int OverscanWidth { get; set; }
    public int OverscanLength { get; set; }
    public bool Invert { get; set; }
    public bool AutoThreshold { get; set; }
}

public sealed class FramePatch
{
    public int Index { get; set; }
    public FrameRecord Frame { get; set; } = new();
}

/// <summary>Everything the page needs after a project is opened.</summary>
public sealed record SessionDto(
    RollData Roll,
    List<FrameRecord> Frames,
    string Notes,
    string ProjectPath,
    string IdfPath,
    string DefaultOutputRoot,
    ProcessDto Process,
    ExportDto Export,
    int ImageVersion,
    bool Dirty);

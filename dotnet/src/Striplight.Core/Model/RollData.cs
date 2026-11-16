namespace Striplight.Core.Model;

/// <summary>Export encoder ids, kept numerically compatible with the Lazarus edition.</summary>
public static class ExportEncoder
{
    public const int BuiltIn = 0;
    public const int TurboJpeg = 1;
}

/// <summary>
/// Metadata for one scanned roll (port of <c>TRollData</c> in lazarus/uTypes.pas).
/// Values come from the QuantumScan IDF plus Striplight's own settings stored in SLF files.
/// </summary>
public sealed class RollData
{
    public const int DefaultJpgQuality = 100;
    public const int DefaultPreviewDownScale = 16;
    public const int DefaultStripDigits = 9;

    public string RollName { get; set; } = "";
    public string RollId { get; set; } = "";
    public string RollNumber { get; set; } = "";

    /// <summary>Directory containing the IDF/SLF file, with trailing separator.</summary>
    public string BasePath { get; set; } = "";
    /// <summary>Directory used for previews; may point at a local cache.</summary>
    public string PreviewBasePath { get; set; } = "";
    /// <summary>Original preview directory base from the IDF.</summary>
    public string PreviewSourceBasePath { get; set; } = "";

    public string StripFolder { get; set; } = "strips";
    public string PreviewFolder { get; set; } = "previews";
    public string PreviewSourceFolder { get; set; } = "";
    public string StripPrefix { get; set; } = "strip";
    public string PreviewPrefix { get; set; } = "preview";
    public int StripDigits { get; set; } = DefaultStripDigits;

    public int StripCount { get; set; }
    /// <summary>Full-resolution strip length along the film, in lines (pixels).</summary>
    public int LengthLines { get; set; } = 4096;
    /// <summary>Full-resolution strip width across the film, in pixels.</summary>
    public int WidthPixels { get; set; } = 4916;
    public int StripPixels { get; set; }
    /// <summary>Divisor between full-resolution strips and previews.</summary>
    public int PreviewDownScale { get; set; } = DefaultPreviewDownScale;
    public int Dpi { get; set; }
    public int JpgQuality { get; set; } = DefaultJpgQuality;
    public int SoftwareContrast { get; set; }
    public int SoftwareBrightness { get; set; }
    public int SoftwareGamma { get; set; }

    // ---- Striplight settings (persisted in SLF <StriplightSettings>) ----
    public int AdjustMethod { get; set; }
    public int AdjustFlags { get; set; }
    public int AdjustContrast { get; set; }
    public int AdjustBrightness { get; set; }
    public int AdjustGamma { get; set; } = 100;
    /// <summary>Strength of the adaptive tone methods, 0..100.</summary>
    public int AdjustStrength { get; set; } = 50;
    public int Sharpness { get; set; }
    public int SharpnessMode { get; set; }
    /// <summary>0 = Quantum folders, 1 = archive list.</summary>
    public int ExportNamingMode { get; set; }
    public string ArchiveList { get; set; } = "";
    /// <summary>Microfilm numbers for the handover report (default: the project folder name).</summary>
    public string ReportMicrofilm { get; set; } = "";
    /// <summary>
    /// Striplight PRO project state as JSON (export folder and options, orientation, size check,
    /// every panel field): saved as &lt;StriplightState&gt; so a reopened project is exactly as left.
    /// </summary>
    public string StriplightState { get; set; } = "";
    public bool ExportGrayscale { get; set; } = true;
    public bool ExportProgressive { get; set; }
    public int ExportEncoder { get; set; } = Model.ExportEncoder.TurboJpeg;

    public int DetectionThreshold { get; set; } = 100;
    public int DetectMinWidth { get; set; } = 252;
    public int DetectMinLength { get; set; } = 252;

    public bool PreviewCacheEnabled { get; set; }
    public bool Loaded { get; set; }

    public RollData Clone() => (RollData)MemberwiseClone();

    /// <summary>Guards against zero divides and empty names after loading.</summary>
    public void Normalise()
    {
        if (PreviewDownScale <= 0) PreviewDownScale = DefaultPreviewDownScale;
        if (LengthLines <= 0) LengthLines = 4096;
        if (WidthPixels <= 0) WidthPixels = 4916;
        if (StripDigits <= 0) StripDigits = DefaultStripDigits;
        if (string.IsNullOrEmpty(StripPrefix)) StripPrefix = "strip";
        if (string.IsNullOrEmpty(PreviewPrefix)) PreviewPrefix = "preview";
        if (string.IsNullOrEmpty(StripFolder)) StripFolder = "strips";
        if (string.IsNullOrEmpty(PreviewFolder)) PreviewFolder = "previews";
        if (string.IsNullOrEmpty(PreviewSourceFolder)) PreviewSourceFolder = PreviewFolder;
    }
}

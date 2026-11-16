namespace Striplight.Core.Model;

/// <summary>
/// One detected or manually placed frame (port of <c>TFrameRecord</c>).
/// Lead/Trail run along the film in global line coordinates (full resolution);
/// Left/Right run across the film in full-resolution pixels.
/// </summary>
public sealed class FrameRecord
{
    public int Index { get; set; }
    public long LeadEdge { get; set; }
    public long TrailEdge { get; set; }
    public int LeftEdge { get; set; }
    public int RightEdge { get; set; }

    /// <summary>Yellow folder-start marker.</summary>
    public bool IsMarker { get; set; }
    /// <summary>Auto-suggested marker (dashed), not yet confirmed.</summary>
    public bool IsSuggested { get; set; }
    public bool IsOversized { get; set; }
    public bool IsUndersized { get; set; }
    /// <summary>Export completed in the current session (not persisted).</summary>
    public bool IsExported { get; set; }

    /// <summary>Quantum-compatible per-frame override; -1 = use global.</summary>
    public int PerFrameBrightness { get; set; } = -1;
    public int PerFrameContrast { get; set; } = -1;
    public int PerFrameGamma { get; set; } = -1;
    /// <summary>Striplight per-frame override; -1 = use global.</summary>
    public int CustomBrightness { get; set; } = -1;
    public int CustomContrast { get; set; } = -1;
    public int CustomGamma { get; set; } = -1;

    /// <summary>0, 90, 180 or 270 (clockwise).</summary>
    public int Rotation { get; set; }
    public bool FlipH { get; set; }
    public bool FlipV { get; set; }
    public bool Negative { get; set; }
    /// <summary>True = this frame uses its own rotation/flip/negative instead of the global ones.</summary>
    public bool HasOverride { get; set; }

    public long Height => TrailEdge - LeadEdge;
    public int Width => RightEdge - LeftEdge;

    public bool HasToneOverride =>
        PerFrameBrightness != -1 || PerFrameContrast != -1 || PerFrameGamma != -1 ||
        CustomBrightness != -1 || CustomContrast != -1 || CustomGamma != -1;

    /// <summary>A frame worth saving: positive height and width.</summary>
    public bool IsPersistable => TrailEdge > LeadEdge && RightEdge > LeftEdge;

    public int LeadStrip(int lengthLines) => lengthLines <= 0 ? 0 : (int)(LeadEdge / lengthLines);
    public int TrailStrip(int lengthLines) => lengthLines <= 0 ? 0 : (int)(TrailEdge / lengthLines);
    public bool SpansStrips(int lengthLines) => TrailStrip(lengthLines) > LeadStrip(lengthLines);

    public FrameRecord Clone() => (FrameRecord)MemberwiseClone();
}

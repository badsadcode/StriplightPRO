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
    /// <summary>
    /// Locked per-frame tone (Striplight PRO): when &gt;= 0 the frame uses its own complete tone
    /// (this method, <see cref="CustomToneFlags"/>, the Custom* values and <see cref="CustomStrength"/>)
    /// and later changes to the global tone never touch it. -1 = not locked (Lazarus behaviour:
    /// any Custom* values replace only those sliders of the global tone).
    /// </summary>
    public int CustomToneMethod { get; set; } = -1;
    public int CustomToneFlags { get; set; }
    public int CustomStrength { get; set; } = -1;

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
        CustomBrightness != -1 || CustomContrast != -1 || CustomGamma != -1 || CustomToneMethod >= 0;

    /// <summary>Gives this frame its own complete tone, independent of the global one.</summary>
    public void LockTone(Imaging.ToneSettings t)
    {
        CustomToneMethod = t.Method; CustomToneFlags = t.Flags;
        CustomContrast = t.Contrast; CustomBrightness = t.Brightness; CustomGamma = t.Gamma;
        CustomStrength = t.Strength;
        // QuantumScan reads only PerFrame* (Quantum ranges): keep them in step for Quantum methods.
        bool quantum = Imaging.ToneAdjust.UsesQuantumRanges(t.Method);
        PerFrameContrast = quantum ? t.Contrast : -1;
        PerFrameBrightness = quantum ? t.Brightness : -1;
        PerFrameGamma = quantum ? t.Gamma : -1;
    }

    public void ClearTone()
    {
        PerFrameBrightness = PerFrameContrast = PerFrameGamma = -1;
        CustomBrightness = CustomContrast = CustomGamma = -1;
        CustomToneMethod = -1; CustomToneFlags = 0; CustomStrength = -1;
    }

    /// <summary>A frame worth saving: positive height and width.</summary>
    public bool IsPersistable => TrailEdge > LeadEdge && RightEdge > LeftEdge;

    public int LeadStrip(int lengthLines) => lengthLines <= 0 ? 0 : (int)(LeadEdge / lengthLines);
    public int TrailStrip(int lengthLines) => lengthLines <= 0 ? 0 : (int)(TrailEdge / lengthLines);
    public bool SpansStrips(int lengthLines) => TrailStrip(lengthLines) > LeadStrip(lengthLines);

    public FrameRecord Clone() => (FrameRecord)MemberwiseClone();
}

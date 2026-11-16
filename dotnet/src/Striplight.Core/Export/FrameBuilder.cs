using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Export;

/// <summary>Global processing applied to frames without their own override.</summary>
public sealed record ProcessSettings
{
    public int Rotation { get; init; }       // 0/90/180/270
    public bool FlipH { get; init; }         // "Mirror"
    public bool FlipV { get; init; }
    public bool Negative { get; init; }
    public ToneSettings Tone { get; init; } = ToneSettings.Neutral;
    public int Sharpness { get; init; }
    public int SharpnessMode { get; init; }
    /// <summary>Strip view orientation: false = CCW (scanner default), true = CW + mirror.</summary>
    public bool SourceRotateCw { get; init; }
}

/// <summary>Resolved per-frame processing.</summary>
public readonly record struct FrameProcessing(int Rotation, bool FlipH, bool FlipV, bool Negative, ToneSettings Tone);

/// <summary>
/// Builds one frame as an 8-bit gray image from its strips (port of
/// <c>TExportWorkerThread.BuildFrameGray</c>). Frames can span several strips: each strip
/// segment is cropped, rotated upright and pasted left to right, then orientation, tone,
/// negative and sharpening are applied — the same order as the Lazarus export.
/// </summary>
public sealed class FrameBuilder(RollData roll, ProcessSettings settings, GrayStripCache cache)
{
    public bool AllowPreviewFallback { get; init; }

    public static FrameProcessing Resolve(FrameRecord f, ProcessSettings s)
    {
        int rot; bool flipH, flipV, neg;
        if (f.HasOverride) { rot = f.Rotation; flipH = f.FlipH; flipV = f.FlipV; neg = f.Negative; }
        else { rot = s.Rotation; flipH = s.FlipH; flipV = s.FlipV; neg = s.Negative; }
        rot = ((rot % 360) + 360) % 360;
        if (rot is not (0 or 90 or 180 or 270)) rot = 0;

        var t = s.Tone;
        if (f.PerFrameContrast != -1 || f.PerFrameBrightness != -1 || f.PerFrameGamma != -1)
        {
            // Quantum per-frame values always use the Quantum-like method.
            t = new ToneSettings(ToneMethod.Quantum, 0,
                f.PerFrameContrast != -1 ? f.PerFrameContrast : 64,
                f.PerFrameBrightness != -1 ? f.PerFrameBrightness : 0,
                f.PerFrameGamma != -1 ? f.PerFrameGamma : 0,
                t.Strength);
        }
        else
        {
            t = t with
            {
                Contrast = f.CustomContrast != -1 ? f.CustomContrast : t.Contrast,
                Brightness = f.CustomBrightness != -1 ? f.CustomBrightness : t.Brightness,
                Gamma = f.CustomGamma != -1 ? f.CustomGamma : t.Gamma,
            };
        }
        return new FrameProcessing(rot, flipH, flipV, neg, t);
    }

    private static int CeilDiv(long value, long divisor) =>
        divisor <= 0 || value <= 0 ? 1 : Math.Max(1, (int)((value + divisor - 1) / divisor));

    /// <param name="sourceAvailable">File-exists check (overridable for tests / network shares).</param>
    public GrayImage Build(FrameRecord f, Func<string, bool>? sourceAvailable = null)
    {
        sourceAvailable ??= p => cache.Contains(p) || File.Exists(p);
        int ds = Math.Max(1, roll.PreviewDownScale);
        int firstStrip = Math.Max(0, f.LeadStrip(roll.LengthLines));
        int lastStrip = Math.Min(roll.StripCount - 1, f.TrailStrip(roll.LengthLines));
        if (lastStrip < firstStrip) lastStrip = firstStrip;

        bool full = true;
        for (int s = firstStrip; s <= lastStrip && full; s++)
            full = sourceAvailable(RollPaths.StripFilePath(roll, s));
        if (!full && !AllowPreviewFallback)
            throw new FileNotFoundException("Missing full strip source for frame; preview fallback is disabled.");

        // Segment rects in strip coordinates: Left/Right = along the film (strip rows),
        // Top/Bottom = across the film (strip columns). Strips are stored on their side.
        var segs = new IntRect?[lastStrip - firstStrip + 1];
        int totalW = 0, maxH = 0;
        for (int s = firstStrip; s <= lastStrip; s++)
        {
            long localLead = Math.Max(0, f.LeadEdge - (long)s * roll.LengthLines);
            long localTrail = Math.Min(roll.LengthLines, f.TrailEdge - (long)s * roll.LengthLines);
            if (localTrail <= localLead) continue;

            int l, r, t, b;
            if (full)
            {
                int srcW = Math.Max(1, roll.WidthPixels), srcH = Math.Max(1, roll.LengthLines);
                l = (int)Math.Clamp(localLead, 0, srcH - 1);
                r = (int)Math.Clamp(localTrail, l + 1, srcH);
                t = Math.Clamp(f.LeftEdge, 0, srcW - 1);
                b = Math.Clamp(f.RightEdge, t + 1, srcW);
            }
            else
            {
                int srcW = CeilDiv(roll.WidthPixels, ds), srcH = CeilDiv(roll.LengthLines, ds);
                l = (int)Math.Clamp(localLead / ds, 0, srcH - 1);
                r = (int)Math.Clamp((localTrail + ds - 1) / ds, l + 1, srcH);
                t = Math.Clamp(f.LeftEdge / ds, 0, srcW - 1);
                b = Math.Clamp((f.RightEdge + ds - 1) / ds, t + 1, srcW);
            }
            segs[s - firstStrip] = new IntRect(l, t, r, b);
            totalW += r - l;
            maxH = Math.Max(maxH, b - t);
        }
        if (totalW <= 0 || maxH <= 0) throw new InvalidOperationException("Frame has no visible image area.");

        var img = new GrayImage(totalW, maxH);
        int offsetX = 0;
        for (int s = firstStrip; s <= lastStrip; s++)
        {
            if (segs[s - firstStrip] is not { } seg) continue;
            string path = full ? RollPaths.StripFilePath(roll, s) : RollPaths.PreviewFilePath(roll, s);
            if (!sourceAvailable(path)) throw new FileNotFoundException("Missing source image: " + path);

            var strip = cache.Acquire(path);
            try
            {
                int top = Math.Clamp(seg.Top, 0, strip.Width - 1);
                int bottom = Math.Clamp(seg.Bottom, top + 1, strip.Width);
                int left = Math.Clamp(seg.Left, 0, strip.Height - 1);
                int right = Math.Clamp(seg.Right, left + 1, strip.Height);
                img.BlitRotated(strip.Data, strip.Width, strip.Height,
                    new IntRect(top, left, bottom, right), settings.SourceRotateCw, offsetX);
                offsetX += right - left;
            }
            finally { cache.Release(path); }
        }

        var p = Resolve(f, settings);
        img.Orient(p.Rotation, p.FlipH, p.FlipV);
        if (!p.Tone.IsNoOp)
            ToneAdjust.ApplyToneGray(img.Data, img.Width, img.Height, img.Width, p.Tone, p.Negative);
        if (p.Negative) img.Negative();
        img.Sharpen(settings.SharpnessMode, settings.Sharpness);
        return img;
    }
}

using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Detection;

public sealed record DetectOptions
{
    public int StripFrom { get; init; }          // 0-based, inclusive
    public int StripTo { get; init; }            // 0-based, inclusive
    public int MinWidthPx { get; init; } = 252;  // full-res pixels
    public int MinHeightPx { get; init; } = 252; // full-res pixels
    public int Brightness { get; init; }         // -100..100
    public int Contrast { get; init; }           // -100..100
    public int Gamma { get; init; } = 100;       // 10..300, 100 = neutral
    public int Threshold { get; init; } = 100;   // 0..255 after adjustment
    public int MergeAcrossGaps { get; init; }    // full-res line gap allowed between runs
    public int LeftInsetPx { get; init; }        // full-res pixels ignored from preview X start
    public int RightInsetPx { get; init; }       // full-res pixels ignored from preview X end
    /// <summary>
    /// Optional 256-entry tone curve applied before thresholding. When set, it replaces the
    /// Brightness/Contrast/Gamma formula, so detection sees exactly what the strip view shows.
    /// </summary>
    public byte[]? ToneLut { get; init; }

    // ---- Advanced controls (QuantumScan-style). Defaults keep the original behaviour.
    /// <summary>A bright pixel only counts inside a run of at least this many bright pixels across the film (full-res px). Removes specks and grey background noise.</summary>
    public int MinRunPx { get; init; }
    /// <summary>Dark gaps up to this size inside a line still join two bright runs (full-res px across the film).</summary>
    public int TouchWidthPx { get; init; }
    /// <summary>Frames longer than this are split into equal parts (full-res lines, 0 = off).</summary>
    public int MaxLengthPx { get; init; }
    /// <summary>Grow every detected frame by this much across the film, each side (full-res px).</summary>
    public int OverscanWidthPx { get; init; }
    /// <summary>Grow every detected frame by this much along the film, each end (full-res lines).</summary>
    public int OverscanLengthPx { get; init; }
    /// <summary>Dark frames on light film: what is dark after the tone curve counts as frame.</summary>
    public bool Invert { get; init; }
    /// <summary>Pick the threshold per strip from its histogram (Otsu); falls back to <see cref="Threshold"/> on strips without clear frames.</summary>
    public bool AutoThreshold { get; init; }
}

/// <summary>
/// Progress after one strip. <see cref="NewFrames"/> holds copies of the frames from index
/// <see cref="FromIndex"/> to the end (the last earlier frame is included again because a
/// frame can grow into the next strip), so a live view can follow the detection.
/// </summary>
public sealed record DetectProgress(int CurrentStrip, int TotalStrips, int StripsRead, int StripsMissing, int FramesFound,
    int StripIndex = 0, int FromIndex = 0, IReadOnlyList<FrameRecord>? NewFrames = null);

/// <summary>
/// Preview-based frame detection (port of lazarus/uFrameDetect.pas). Detection applies
/// the detection sliders in memory, then finds bright bands against the dark film.
/// Original strip files are never modified.
/// </summary>
public static class FrameDetector
{
    /// <param name="loadPreview">Returns the decoded preview for a strip, or null if missing.</param>
    public static List<FrameRecord> Detect(RollData roll, DetectOptions options,
        Func<int, DecodedImage?> loadPreview, IProgress<DetectProgress>? progress = null,
        CancellationToken cancel = default)
    {
        var frames = new List<FrameRecord>();
        if (!roll.Loaded || roll.StripCount <= 0) return frames;

        int from = Math.Clamp(options.StripFrom, 0, roll.StripCount - 1);
        int to = Math.Clamp(options.StripTo, 0, roll.StripCount - 1);
        if (to < from) return frames;

        var lumLut = options.ToneLut is { Length: 256 } t ? t.Select(b => (int)b).ToArray() : BuildLumLut(options);
        int total = to - from + 1, read = 0, missing = 0, cur = 0, reported = 0;

        for (int strip = from; strip <= to; strip++)
        {
            cancel.ThrowIfCancellationRequested();
            cur++;
            DecodedImage? img = null;
            try { img = loadPreview(strip); }
            catch (IOException) { }
            catch (TurboJpegException) { }

            if (img is null) missing++;
            else
            {
                read++;
                DetectInStrip(roll, options, strip, img, lumLut, frames);
            }
            if (progress is not null)
            {
                int fromIdx = Math.Max(0, reported - 1);
                var slice = frames.Skip(fromIdx).Select(f => f.Clone()).ToList();
                reported = frames.Count;
                progress.Report(new DetectProgress(cur, total, read, missing, frames.Count, strip, fromIdx, slice));
            }
        }
        return PostProcess(roll, options, frames);
    }

    /// <summary>Maximum frame length (equal split) and overscan, applied once detection is done.</summary>
    internal static List<FrameRecord> PostProcess(RollData roll, DetectOptions o, List<FrameRecord> frames)
    {
        if (o.MaxLengthPx <= 0 && o.OverscanWidthPx == 0 && o.OverscanLengthPx == 0) return frames;
        long rollEnd = (long)roll.StripCount * roll.LengthLines;
        var result = new List<FrameRecord>(frames.Count);
        foreach (var f in frames)
        {
            long len = f.TrailEdge - f.LeadEdge;
            int parts = o.MaxLengthPx > 0 && len > o.MaxLengthPx ? (int)Math.Ceiling(len / (double)o.MaxLengthPx) : 1;
            for (int k = 0; k < parts; k++)
            {
                var p = f.Clone();
                p.LeadEdge = f.LeadEdge + len * k / parts;
                p.TrailEdge = f.LeadEdge + len * (k + 1) / parts;
                result.Add(p);
            }
        }
        foreach (var f in result)
        {
            f.LeadEdge = Math.Max(0, f.LeadEdge - o.OverscanLengthPx);
            f.TrailEdge = Math.Min(rollEnd, f.TrailEdge + o.OverscanLengthPx);
            f.LeftEdge = Math.Clamp(f.LeftEdge - o.OverscanWidthPx, 0, roll.WidthPixels);
            f.RightEdge = Math.Clamp(f.RightEdge + o.OverscanWidthPx, 0, roll.WidthPixels);
        }
        result.RemoveAll(f => f.TrailEdge <= f.LeadEdge || f.RightEdge <= f.LeftEdge);
        for (int i = 0; i < result.Count; i++) result[i].Index = i;
        return result;
    }

    /// <summary>
    /// Otsu's threshold of a 256-bin histogram, or -1 when the two classes are not clearly
    /// apart (a strip of empty film, or one big frame): then the manual threshold is used.
    /// </summary>
    internal static int OtsuThreshold(long[] hist)
    {
        long total = 0, sumAll = 0;
        for (int i = 0; i < 256; i++) { total += hist[i]; sumAll += i * hist[i]; }
        if (total == 0) return -1;
        long wB = 0, sumB = 0;
        double best = -1;
        int bestT = -1;
        double bestMeanB = 0, bestMeanF = 0;
        for (int t = 0; t < 255; t++)
        {
            wB += hist[t];
            if (wB == 0) continue;
            long wF = total - wB;
            if (wF == 0) break;
            sumB += t * hist[t];
            double mB = sumB / (double)wB, mF = (sumAll - sumB) / (double)wF;
            double between = (double)wB * wF * (mB - mF) * (mB - mF);
            if (between > best) { best = between; bestT = t + 1; bestMeanB = mB; bestMeanF = mF; }
        }
        // Classes closer than 40 grey levels: no real frame/background split on this strip.
        double minorShare = Math.Min(hist.Take(bestT).Sum(), total - hist.Take(bestT).Sum()) / (double)total;
        return bestT > 0 && bestMeanF - bestMeanB >= 40 && minorShare >= 0.02 ? bestT : -1;
    }

    internal static int[] BuildLumLut(DetectOptions o)
    {
        var lut = new int[256];
        for (int x = 0; x < 256; x++)
        {
            double v = x / 255.0;
            double g = o.Gamma / 100.0;
            if (g <= 0.01) g = 1.0;
            v = Math.Pow(v, 1.0 / g);
            double c = (100.0 + o.Contrast) / 100.0;
            v = ((v - 0.5) * c) + 0.5;
            v += o.Brightness / 100.0;
            lut[x] = Math.Clamp((int)Math.Round(v * 255.0), 0, 255);
        }
        return lut;
    }

    /// <summary>Scans one decoded preview (gray or BGRA) and appends/merges the frames it finds.</summary>
    internal static void DetectInStrip(RollData roll, DetectOptions o, int stripIdx, DecodedImage img,
        int[] lumLut, List<FrameRecord> frames)
    {
        int ds = Math.Max(1, roll.PreviewDownScale);
        int minWPrev = Math.Max(1, o.MinWidthPx / ds);
        int minHPrev = Math.Max(1, o.MinHeightPx / ds);
        int threshold = Math.Clamp(o.Threshold, 1, 254);
        int minRun = Math.Max(1, (int)Math.Round(o.MinRunPx / (double)ds));
        int touchW = Math.Max(0, (int)Math.Round(o.TouchWidthPx / (double)ds));
        // Dark lines allowed inside a frame within one strip (the same gap joins frames across strips).
        int touchL = Math.Max(0, o.MergeAcrossGaps / ds);

        int w = img.Width, h = img.Height;
        int scanMinX = Math.Clamp(o.LeftInsetPx / ds, 0, Math.Max(0, w - 1));
        int scanMaxX = Math.Clamp(w - 1 - o.RightInsetPx / ds, 0, Math.Max(0, w - 1));
        if (scanMaxX < scanMinX) return;

        var px = img.Pixels;
        int ch = img.Channels, stride = img.Stride;
        // BGRA: lum = (R*30 + G*59 + B*11) / 100, as the Pascal PixelLum.
        int Lum(int p) => lumLut[ch == 1 ? px[p] : (px[p + 2] * 30 + px[p + 1] * 59 + px[p] * 11) / 100];

        if (o.AutoThreshold)
        {
            var hist = new long[256];
            for (int y = 0; y < h; y += 2)
                for (int x = scanMinX, p = y * stride + scanMinX * ch; x <= scanMaxX; x += 2, p += 2 * ch)
                    hist[Lum(p)]++;
            int t = OtsuThreshold(hist);
            if (t > 0) threshold = Math.Clamp(t, 1, 254);
        }
        bool invert = o.Invert;

        bool inRun = false;
        int runStartY = 0, runEndY = 0, runMinX = 0, runMaxX = 0;

        void FinishRun()
        {
            if (!inRun) return;
            inRun = false;
            if (runEndY - runStartY + 1 < minHPrev) return;
            long stripBase = (long)stripIdx * roll.LengthLines;
            var f = new FrameRecord
            {
                LeadEdge = stripBase + (long)runStartY * ds,
                TrailEdge = stripBase + (long)(runEndY + 1) * ds,
                LeftEdge = Math.Clamp(runMinX * ds, 0, roll.WidthPixels),
                RightEdge = Math.Clamp((runMaxX + 1) * ds, 0, roll.WidthPixels),
            };
            if (f.TrailEdge > (long)(stripIdx + 1) * roll.LengthLines) f.TrailEdge = (long)(stripIdx + 1) * roll.LengthLines;
            if (f.TrailEdge > f.LeadEdge && f.RightEdge > f.LeftEdge) AppendOrMerge(frames, f, o.MergeAcrossGaps);
        }

        for (int y = 0; y < h; y++)
        {
            int bright = 0, rowMin = w, rowMax = -1;
            // Bright runs across the film; gaps up to touchW join runs; runs shorter than
            // minRun are noise. With the defaults (minRun 1, touchW 0) every bright pixel counts.
            int segStart = -1, segEnd = -1, segBright = 0;
            void CloseSegment()
            {
                if (segStart < 0) return;
                if (segEnd - segStart + 1 >= minRun)
                {
                    bright += segBright;
                    if (segStart < rowMin) rowMin = segStart;
                    if (segEnd > rowMax) rowMax = segEnd;
                }
                segStart = -1; segBright = 0;
            }
            int p = y * stride + scanMinX * ch;
            for (int x = scanMinX; x <= scanMaxX; x++, p += ch)
            {
                if ((Lum(p) >= threshold) == invert) continue;
                if (segStart >= 0 && x - segEnd - 1 > touchW) CloseSegment();
                if (segStart < 0) segStart = x;
                segEnd = x;
                segBright++;
            }
            CloseSegment();
            if (bright >= minWPrev && rowMax - rowMin + 1 >= minWPrev)
            {
                if (!inRun) { inRun = true; runStartY = y; runMinX = rowMin; runMaxX = rowMax; }
                else { runMinX = Math.Min(runMinX, rowMin); runMaxX = Math.Max(runMaxX, rowMax); }
                runEndY = y;
            }
            else if (inRun && y - runEndY > touchL) FinishRun();
        }
        FinishRun();
    }

    private static bool RangesOverlapEnough(int a1, int a2, int b1, int b2)
    {
        int overlap = Math.Min(a2, b2) - Math.Max(a1, b1);
        int narrowest = Math.Min(a2 - a1, b2 - b1);
        return overlap > 0 && (narrowest <= 0 || overlap >= narrowest / 3);
    }

    private static void AppendOrMerge(List<FrameRecord> frames, FrameRecord f, int gapLines)
    {
        if (frames.Count > 0)
        {
            var last = frames[^1];
            if (f.LeadEdge - last.TrailEdge <= gapLines &&
                RangesOverlapEnough(last.LeftEdge, last.RightEdge, f.LeftEdge, f.RightEdge))
            {
                last.TrailEdge = Math.Max(last.TrailEdge, f.TrailEdge);
                last.LeftEdge = Math.Min(last.LeftEdge, f.LeftEdge);
                last.RightEdge = Math.Max(last.RightEdge, f.RightEdge);
                return;
            }
        }
        f.Index = frames.Count;
        frames.Add(f);
    }
}

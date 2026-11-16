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
}

public sealed record DetectProgress(int CurrentStrip, int TotalStrips, int StripsRead, int StripsMissing, int FramesFound);

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

        var lumLut = BuildLumLut(options);
        int total = to - from + 1, read = 0, missing = 0, cur = 0;

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
            progress?.Report(new DetectProgress(cur, total, read, missing, frames.Count));
        }
        return frames;
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

        int w = img.Width, h = img.Height;
        int scanMinX = Math.Clamp(o.LeftInsetPx / ds, 0, Math.Max(0, w - 1));
        int scanMaxX = Math.Clamp(w - 1 - o.RightInsetPx / ds, 0, Math.Max(0, w - 1));
        if (scanMaxX < scanMinX) return;

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

        var px = img.Pixels;
        int ch = img.Channels, stride = img.Stride;
        for (int y = 0; y < h; y++)
        {
            int bright = 0, rowMin = w, rowMax = -1;
            int p = y * stride + scanMinX * ch;
            for (int x = scanMinX; x <= scanMaxX; x++, p += ch)
            {
                // BGRA: lum = (R*30 + G*59 + B*11) / 100, as the Pascal PixelLum.
                int lum = ch == 1 ? px[p] : (px[p + 2] * 30 + px[p + 1] * 59 + px[p] * 11) / 100;
                if (lumLut[lum] >= threshold)
                {
                    bright++;
                    if (x < rowMin) rowMin = x;
                    if (x > rowMax) rowMax = x;
                }
            }
            if (bright >= minWPrev && rowMax - rowMin + 1 >= minWPrev)
            {
                if (!inRun) { inRun = true; runStartY = y; runMinX = rowMin; runMaxX = rowMax; }
                else { runMinX = Math.Min(runMinX, rowMin); runMaxX = Math.Max(runMaxX, rowMax); }
                runEndY = y;
            }
            else FinishRun();
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

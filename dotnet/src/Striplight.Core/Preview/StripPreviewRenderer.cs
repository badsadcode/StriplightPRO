using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Preview;

/// <summary>
/// Produces the strip images shown in the strip view (port of <c>TStripView.LoadPageBitmaps</c>):
/// preview JPEG → gray → tone adjustment → rotated upright → JPEG for the WebView.
/// Adaptive methods run on the whole strip here, while export runs them per frame, so the
/// strip view is a close guide for those methods; the frame preview shows the exact result.
/// </summary>
public static class StripPreviewRenderer
{
    /// <param name="frameTones">
    /// Frames with their own (locked) tone: inside each frame the strip shows that tone instead
    /// of the global one, so the strip view matches what the frame will export as.
    /// </param>
    public static byte[]? RenderStrip(RollData roll, int stripIdx, ToneSettings tone, bool negativePolarity,
        bool rotateCw, int jpegQuality = 88, IReadOnlyList<(FrameRecord Frame, ToneSettings Tone)>? frameTones = null)
    {
        string path = RollPaths.PreviewFilePath(roll, stripIdx);
        if (!File.Exists(path)) return null;

        var d = TurboJpeg.DecodeFile(path, TurboJpeg.PixelFormatGray);
        if (d is null) return null;

        byte[]? original = frameTones is { Count: > 0 } ? (byte[])d.Pixels.Clone() : null;
        if (!tone.IsNoOp)
            ToneAdjust.ApplyToneGray(d.Pixels, d.Width, d.Height, d.Width, tone, negativePolarity);
        if (original is not null)
            foreach (var (f, t) in frameTones!)
                ApplyFrameTone(roll, stripIdx, d.Pixels, original, d.Width, d.Height, f, t, negativePolarity);

        // Rotate the whole strip upright: CCW (scanner default) or CW + mirror (= transpose).
        var upright = new GrayImage(d.Height, d.Width, clear: false);
        upright.BlitRotated(d.Pixels, d.Width, d.Height, new IntRect(0, 0, d.Width, d.Height), rotateCw, 0);
        return TurboJpeg.EncodeGray(upright, jpegQuality, progressive: false);
    }

    /// <summary>Re-tones the part of a stored (sideways) preview strip covered by one frame.</summary>
    internal static void ApplyFrameTone(RollData roll, int stripIdx, byte[] pixels, byte[] original, int width, int height,
        FrameRecord f, ToneSettings tone, bool negativePolarity)
    {
        // Stored strips: rows run along the film (lines), columns across it (pixels), both downscaled.
        double ds = roll.LengthLines > 0 ? roll.LengthLines / (double)height : 1;
        double dsAcross = roll.WidthPixels > 0 ? roll.WidthPixels / (double)width : ds;
        long start = (long)stripIdx * roll.LengthLines;
        int y0 = (int)Math.Floor(Math.Max(0, f.LeadEdge - start) / ds);
        int y1 = (int)Math.Ceiling(Math.Min(roll.LengthLines, f.TrailEdge - start) / ds);
        int x0 = (int)Math.Floor(Math.Max(0, f.LeftEdge) / dsAcross);
        int x1 = (int)Math.Ceiling(Math.Min(roll.WidthPixels, f.RightEdge) / dsAcross);
        y0 = Math.Clamp(y0, 0, height); y1 = Math.Clamp(y1, 0, height);
        x0 = Math.Clamp(x0, 0, width); x1 = Math.Clamp(x1, 0, width);
        int w = x1 - x0, h = y1 - y0;
        if (w <= 0 || h <= 0) return;
        for (int y = y0; y < y1; y++)
            Array.Copy(original, y * width + x0, pixels, y * width + x0, w);
        if (!tone.IsNoOp)
            ToneAdjust.ApplyToneGray(pixels.AsSpan(y0 * width + x0, (h - 1) * width + w), w, h, width, tone, negativePolarity);
    }

    /// <summary>
    /// The exact frame as export would produce it, downscaled so its longest side is at
    /// most <paramref name="maxSide"/> pixels, as a JPEG.
    /// </summary>
    public static byte[] RenderFrame(FrameBuilder builder, FrameRecord frame, int maxSide = 2400, int jpegQuality = 90)
    {
        var img = builder.Build(frame);
        int factor = Math.Max(1, (int)Math.Ceiling(Math.Max(img.Width, img.Height) / (double)maxSide));
        return TurboJpeg.EncodeGray(img.Downscale(factor), jpegQuality, progressive: false);
    }
}

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
    public static byte[]? RenderStrip(RollData roll, int stripIdx, ToneSettings tone, bool negativePolarity,
        bool rotateCw, int jpegQuality = 88)
    {
        string path = RollPaths.PreviewFilePath(roll, stripIdx);
        if (!File.Exists(path)) return null;

        var d = TurboJpeg.DecodeFile(path, TurboJpeg.PixelFormatGray);
        if (d is null) return null;

        if (!tone.IsNoOp)
            ToneAdjust.ApplyToneGray(d.Pixels, d.Width, d.Height, d.Width, tone, negativePolarity);

        // Rotate the whole strip upright: CCW (scanner default) or CW + mirror (= transpose).
        var upright = new GrayImage(d.Height, d.Width, clear: false);
        upright.BlitRotated(d.Pixels, d.Width, d.Height, new IntRect(0, 0, d.Width, d.Height), rotateCw, 0);
        return TurboJpeg.EncodeGray(upright, jpegQuality, progressive: false);
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

namespace Striplight.Core.Imaging;

/// <summary>Integer rectangle, right/bottom exclusive (like LCL's TRect).</summary>
public readonly record struct IntRect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
}

/// <summary>
/// An 8-bit grayscale image, <see cref="Width"/> bytes per row, top row first.
/// Port of <c>TGrayFrame</c> and its operations from lazarus/uFrameGray.pas.
/// </summary>
public sealed class GrayImage
{
    private const int BlockRows = 32;

    public int Width { get; private set; }
    public int Height { get; private set; }
    public byte[] Data { get; private set; }

    public GrayImage(int width, int height, bool clear = true)
    {
        if (width <= 0 || height <= 0) throw new ArgumentException("Frame has no visible image area.");
        Width = width;
        Height = height;
        Data = clear ? new byte[(long)width * height] : GC.AllocateUninitializedArray<byte>(checked(width * height));
    }

    public GrayImage(int width, int height, byte[] data)
    {
        if (data.Length < (long)width * height) throw new ArgumentException("Buffer too small.", nameof(data));
        Width = width;
        Height = height;
        Data = data;
    }

    public GrayImage Clone() => new(Width, Height, (byte[])Data.Clone());

    /// <summary>
    /// Copies the crop rectangle of a strip into this image, rotated the way the strip view
    /// shows it, with its left edge at <paramref name="dstX"/> and its top at row 0.
    /// transpose = false: rotate counter-clockwise. transpose = true: rotate clockwise then mirror.
    /// </summary>
    public void BlitRotated(ReadOnlySpan<byte> src, int srcW, int srcH, IntRect crop, bool transpose, int dstX)
    {
        int x0 = Math.Max(0, crop.Left), y0 = Math.Max(0, crop.Top);
        int cw = Math.Min(srcW, crop.Right) - x0, ch = Math.Min(srcH, crop.Bottom) - y0;
        if (cw <= 0 || ch <= 0 || dstX < 0) return;

        // The rotated segment is ch wide and cw high. Clip it to the destination.
        int segW = ch, segH = cw;
        if (dstX + segW > Width) segW = Width - dstX;
        if (segH > Height) segH = Height;
        if (segW <= 0 || segH <= 0) return;

        // Destination row k takes source column x0+k (transpose) or x0+cw-1-k (CCW);
        // destination column dstX+sy takes source row y0+sy. Blocks of rows keep both
        // source and destination in the CPU cache.
        var dst = Data.AsSpan();
        int stride = Width;
        for (int row0 = 0; row0 < segH; row0 += BlockRows)
        {
            int rowCount = Math.Min(BlockRows, segH - row0);
            for (int sy = 0; sy < segW; sy++)
            {
                int srcRow = (y0 + sy) * srcW;
                int d = row0 * stride + dstX + sy;
                if (transpose)
                {
                    int srcCol = x0 + row0;
                    for (int k = 0; k < rowCount; k++, d += stride) dst[d] = src[srcRow + srcCol + k];
                }
                else
                {
                    int srcCol = x0 + cw - 1 - row0;
                    for (int k = 0; k < rowCount; k++, d += stride) dst[d] = src[srcRow + srcCol - k];
                }
            }
        }
    }

    /// <summary>Rotates by 0/90/180/270 degrees clockwise, then mirrors.</summary>
    public void Orient(int rotation, bool flipH, bool flipV)
    {
        switch (rotation)
        {
            case 90: RotateQuarter(clockwise: true); break;
            case 180: MirrorRows(); SwapRows(); break; // two quarter turns = mirror both ways
            case 270: RotateQuarter(clockwise: false); break;
        }
        if (flipH) MirrorRows();
        if (flipV) SwapRows();
    }

    private void RotateQuarter(bool clockwise)
    {
        // Clockwise:         (x, y) -> (H-1-y, x)
        // Counter-clockwise: (x, y) -> (y, W-1-x)
        int nw = Height, nh = Width;
        var src = Data;
        var dst = GC.AllocateUninitializedArray<byte>(nw * nh);
        for (int row0 = 0; row0 < nh; row0 += BlockRows)
        {
            int rowCount = Math.Min(BlockRows, nh - row0);
            for (int sy = 0; sy < Height; sy++)
            {
                int srcRow = sy * Width;
                if (clockwise)
                {
                    int d = row0 * nw + (Height - 1 - sy);
                    for (int k = 0; k < rowCount; k++, d += nw) dst[d] = src[srcRow + row0 + k];
                }
                else
                {
                    int d = row0 * nw + sy;
                    int srcCol = Width - 1 - row0;
                    for (int k = 0; k < rowCount; k++, d += nw) dst[d] = src[srcRow + srcCol - k];
                }
            }
        }
        Data = dst;
        Width = nw;
        Height = nh;
    }

    private void MirrorRows()
    {
        for (int y = 0; y < Height; y++) Data.AsSpan(y * Width, Width).Reverse();
    }

    private void SwapRows()
    {
        if (Height < 2) return;
        var tmp = new byte[Width];
        for (int y = 0; y < Height / 2; y++)
        {
            var a = Data.AsSpan(y * Width, Width);
            var b = Data.AsSpan((Height - 1 - y) * Width, Width);
            a.CopyTo(tmp);
            b.CopyTo(a);
            tmp.CopyTo(b);
        }
    }

    public void Negative()
    {
        var d = Data.AsSpan(0, Width * Height);
        for (int i = 0; i < d.Length; i++) d[i] = (byte)(255 - d[i]);
    }

    /// <summary>3x3 sharpening, same as ApplySharpnessFilter in the Lazarus main form.</summary>
    public void Sharpen(int mode, int amount)
    {
        if (Width < 3 || Height < 3) return;
        amount = Math.Clamp(amount, 0, 100);
        if (amount <= 0) return;
        double strength = mode switch
        {
            1 => 0.45 + amount / 70.0, // unsharp
            2 => 0.65 + amount / 48.0, // text crisp
            3 => 0.90 + amount / 36.0, // high-pass strong
            _ => 0.25 + amount / 120.0, // soft
        };
        var src = (byte[])Data.Clone();
        int w = Width;
        // The outermost rows and columns keep their original values.
        for (int y = 1; y < Height - 1; y++)
        {
            int up = (y - 1) * w, mid = y * w, down = (y + 1) * w;
            for (int x = 1; x < w - 1; x++)
            {
                int c = src[mid + x];
                int sum = src[up + x - 1] + src[up + x] + src[up + x + 1] +
                          src[mid + x - 1] + c + src[mid + x + 1] +
                          src[down + x - 1] + src[down + x] + src[down + x + 1];
                if (sum == 9 * c) continue;
                double blur = sum / 9.0;
                int v = (int)Math.Round(c + (c - blur) * strength);
                Data[mid + x] = (byte)Math.Clamp(v, 0, 255);
            }
        }
    }

    /// <summary>Box-downscales by an integer factor (used for quick on-screen frame previews).</summary>
    public GrayImage Downscale(int factor)
    {
        if (factor <= 1) return this;
        int nw = Math.Max(1, Width / factor), nh = Math.Max(1, Height / factor);
        var dst = new GrayImage(nw, nh, clear: false);
        int area = factor * factor;
        for (int y = 0; y < nh; y++)
            for (int x = 0; x < nw; x++)
            {
                int sum = 0;
                for (int yy = 0; yy < factor; yy++)
                {
                    int row = (y * factor + yy) * Width + x * factor;
                    for (int xx = 0; xx < factor; xx++) sum += Data[row + xx];
                }
                dst.Data[y * nw + x] = (byte)(sum / area);
            }
        return dst;
    }
}

namespace Striplight.Core.Imaging;

/// <summary>Tone method ids, numerically identical to the Lazarus edition (saved in SLF files).</summary>
public static class ToneMethod
{
    public const int Striplight = 0;        // Striplight current
    public const int Quantum = 1;           // Quantum-like
    public const int Curve = 2;             // Original curve
    public const int CurveGamma12 = 3;      // Gamma 1.2 curve
    public const int CurveQuantum = 4;      // Original curve + Quantum sliders
    public const int AutoLevels = 5;        // Per-frame black/white point stretch
    public const int Clahe = 6;             // Adaptive local contrast
    public const int LocalExposure = 7;     // Lift dark regions, pull back bright regions
    public const int BackgroundFlatten = 8; // Even out the paper/background brightness
    public const int Count = 9;
}

[Flags]
public enum ToneFlags
{
    None = 0,
    ShadowLift = 1,
    HighlightRecovery = 2,
    SCurve = 4,
    DocumentRescue = 8,
    SoftContrast = 16,
}

/// <summary>Complete tone setting for one image.</summary>
public readonly record struct ToneSettings(
    int Method, int Flags, int Contrast, int Brightness, int Gamma, int Strength)
{
    public static ToneSettings Neutral => new(ToneMethod.Striplight, 0, 0, 0, 100, ToneAdjust.StrengthDefault);
    public bool IsNoOp => ToneAdjust.IsNoOp(Method, Flags, Contrast, Brightness, Gamma, Strength);
}

/// <summary>
/// Tone adjustment shared by the strip view, the frame preview and the export, so what
/// is previewed is what gets exported. Line-for-line port of lazarus/uToneAdjust.pas;
/// Pascal's <c>Round</c> is banker's rounding, which <see cref="Math.Round(double)"/> matches.
///
/// Classic methods (0..4) are a single 256-entry lookup table. Adaptive methods (5..8)
/// analyse the image first. Everything works on 8-bit grayscale buffers.
/// </summary>
public static class ToneAdjust
{
    public const int StrengthMin = 0;
    public const int StrengthMax = 100;
    public const int StrengthDefault = 50;

    private const int NormaliseClip = 5; // auto-levels strength used inside the local methods

    public static string MethodName(int method) => method switch
    {
        ToneMethod.Striplight => "Striplight current",
        ToneMethod.Quantum => "Quantum-like",
        ToneMethod.Curve => "Original curve",
        ToneMethod.CurveGamma12 => "Gamma 1.2 curve",
        ToneMethod.CurveQuantum => "Original curve + Quantum sliders",
        ToneMethod.AutoLevels => "Auto levels",
        ToneMethod.Clahe => "Local contrast (CLAHE)",
        ToneMethod.LocalExposure => "Exposure balance",
        ToneMethod.BackgroundFlatten => "Background flatten",
        _ => "Method " + method,
    };

    public static bool IsAdaptive(int method) => method >= ToneMethod.AutoLevels && method < ToneMethod.Count;

    /// <summary>Methods whose sliders use Quantum ranges (contrast -128..255 neutral 64, brightness -128..127, gamma -255..255).</summary>
    public static bool UsesQuantumRanges(int method) => method is ToneMethod.Quantum or ToneMethod.CurveQuantum;

    private static byte ClampByte(long v) => v < 0 ? (byte)0 : v > 255 ? (byte)255 : (byte)v;

    private static byte ClampByte(double v) => double.IsNaN(v) ? (byte)0 : ClampByte((long)Math.Round(v));

    // ------------------------------------------------------------ classic LUTs

    private static readonly int[] CurveIn = [0, 273, 546, 819, 1092, 1365, 1638, 1911, 2184, 2457, 2730, 3003, 3276, 3549, 3822, 4095];
    private static readonly int[] CurveOut = [0, 429, 764, 1071, 1361, 1639, 1908, 2170, 2425, 2675, 2921, 3162, 3423, 3635, 3866, 4095];
    private static readonly int[] CurveGamma12Out = [0, 429, 764, 1071, 1361, 1639, 1908, 2170, 2425, 2675, 2921, 3162, 3400, 3635, 3866, 4095];

    /// <summary>
    /// Lookup table for a classic method. Adaptive methods fall back to the Striplight
    /// method: their sliders use the Striplight ranges and run after the adaptive step.
    /// </summary>
    public static byte[] BuildLut(int method, int flags, int contrast, int brightness, int gamma)
    {
        if (IsAdaptive(method) || method < 0 || method >= ToneMethod.Count) method = ToneMethod.Striplight;
        var lut = new byte[256];
        for (int x = 0; x < 256; x++) lut[x] = AdjustChannel(x, method, flags, contrast, brightness, gamma);
        return lut;
    }

    private static byte AdjustChannel(int value, int method, int flags, int contrast, int brightness, int gamma)
    {
        double v = value / 255.0;
        if (method is ToneMethod.Curve or ToneMethod.CurveGamma12 or ToneMethod.CurveQuantum)
        {
            int[] outTable = method == ToneMethod.CurveGamma12 ? CurveGamma12Out : CurveOut;
            int in12 = (int)Math.Round(v * 4095.0);
            int out12 = outTable[^1];
            for (int i = 0; i < CurveIn.Length - 1; i++)
            {
                if (in12 <= CurveIn[i + 1])
                {
                    out12 = outTable[i] + (int)Math.Round(
                        (double)((long)(in12 - CurveIn[i]) * (outTable[i + 1] - outTable[i])) /
                        (CurveIn[i + 1] - CurveIn[i]));
                    break;
                }
            }
            v = out12 / 4095.0;
        }

        double g, c;
        if (method is ToneMethod.Quantum or ToneMethod.CurveQuantum)
        {
            g = Math.Pow(2.0, -gamma / 255.0);
            if (g <= 0.01) g = 1.0;
            v = Math.Pow(v, 1.0 / g);
            c = Math.Pow(2.0, (contrast - 64) / 128.0);
            v = ((v - 0.5) * c) + 0.5;
            v -= brightness / 510.0;
        }
        else
        {
            g = gamma / 100.0;
            if (g <= 0.01) g = 1.0;
            v = Math.Pow(v, 1.0 / g);
            c = (100.0 + contrast) / 100.0;
            v = ((v - 0.5) * c) + 0.5;
            v += brightness / 100.0;
        }

        if ((flags & (int)ToneFlags.ShadowLift) != 0)
            v = Math.Pow(Math.Max(0.0, Math.Min(1.0, v)), 1.0 / 1.45);
        if ((flags & (int)ToneFlags.HighlightRecovery) != 0)
            v = v / (v + (1.0 - v) * 1.20);
        if ((flags & (int)ToneFlags.SCurve) != 0)
            v = v * v * (3.0 - 2.0 * v);
        if ((flags & (int)ToneFlags.DocumentRescue) != 0)
        {
            v = Math.Pow(Math.Max(0.0, Math.Min(1.0, v)), 1.0 / 1.35);
            if (v > 0.70) v = 0.70 + (v - 0.70) * 0.72;
        }
        if ((flags & (int)ToneFlags.SoftContrast) != 0)
        {
            v = ((v - 0.5) * 0.82) + 0.5;
            v = Math.Pow(Math.Max(0.0, Math.Min(1.0, v)), 1.0 / 1.08);
        }
        return ClampByte(v * 255.0);
    }

    /// <summary>True when the whole adjustment would leave the image unchanged.</summary>
    public static bool IsNoOp(int method, int flags, int contrast, int brightness, int gamma, int strength)
    {
        if (flags != 0) return false;
        return method switch
        {
            ToneMethod.Quantum or ToneMethod.CurveQuantum => contrast == 64 && brightness == 0 && gamma == 0,
            ToneMethod.Curve or ToneMethod.CurveGamma12 => false,
            ToneMethod.AutoLevels => false,
            ToneMethod.Clahe or ToneMethod.LocalExposure or ToneMethod.BackgroundFlatten =>
                strength <= 0 && contrast == 0 && brightness == 0 && gamma == 100,
            _ => contrast == 0 && brightness == 0 && gamma == 100,
        };
    }

    public static void ApplyLut(Span<byte> data, int width, int height, int stride, ReadOnlySpan<byte> lut)
    {
        if (width <= 0 || height <= 0) return;
        for (int y = 0; y < height; y++)
        {
            var row = data.Slice(y * stride, width);
            for (int x = 0; x < row.Length; x++) row[x] = lut[row[x]];
        }
    }

    // ------------------------------------------------------------ entry points

    /// <summary>
    /// Complete adjustment of an 8-bit grayscale buffer, in place.
    /// <paramref name="invertedPolarity"/>: the image is still a negative at this point
    /// (light text on dark), which matters for background flattening.
    /// </summary>
    public static void ApplyToneGray(Span<byte> data, int width, int height, int stride,
        in ToneSettings t, bool invertedPolarity)
    {
        if (width <= 0 || height <= 0) return;
        if (t.IsNoOp) return;

        byte[] lut;
        if (IsAdaptive(t.Method))
        {
            ApplyAdaptiveGray(data, width, height, stride, t.Method, t.Strength, invertedPolarity);
            if (IsNoOp(ToneMethod.Striplight, t.Flags, t.Contrast, t.Brightness, t.Gamma, 0)) return;
            lut = BuildLut(ToneMethod.Striplight, t.Flags, t.Contrast, t.Brightness, t.Gamma);
        }
        else
        {
            lut = BuildLut(t.Method, t.Flags, t.Contrast, t.Brightness, t.Gamma);
        }
        ApplyLut(data, width, height, stride, lut);
    }

    /// <summary>Runs only the image-dependent step of an adaptive method.</summary>
    public static void ApplyAdaptiveGray(Span<byte> data, int width, int height, int stride,
        int method, int strength, bool invertedPolarity)
    {
        if (width <= 0 || height <= 0) return;
        strength = Math.Clamp(strength, StrengthMin, StrengthMax);
        // The three local methods also bring the frame to full range (a gentle auto
        // levels), so one setting copes with dark, bright and mixed frames on one roll.
        switch (method)
        {
            case ToneMethod.AutoLevels:
                AutoLevelsGray(data, width, height, stride, strength);
                break;
            case ToneMethod.Clahe when strength > 0:
                AutoLevelsGray(data, width, height, stride, NormaliseClip);
                ClaheGray(data, width, height, stride, strength);
                break;
            case ToneMethod.LocalExposure when strength > 0:
                AutoLevelsGray(data, width, height, stride, NormaliseClip);
                LocalExposureGray(data, width, height, stride, strength);
                break;
            case ToneMethod.BackgroundFlatten when strength > 0:
                // Flattening assumes a light background: work on the inverted negative.
                if (invertedPolarity) InvertGray(data, width, height, stride);
                BackgroundFlattenGray(data, width, height, stride, strength);
                AutoLevelsGray(data, width, height, stride, NormaliseClip);
                if (invertedPolarity) InvertGray(data, width, height, stride);
                break;
        }
    }

    // ------------------------------------------------------------ helpers

    private static void InvertGray(Span<byte> data, int width, int height, int stride)
    {
        for (int y = 0; y < height; y++)
        {
            var row = data.Slice(y * stride, width);
            for (int x = 0; x < row.Length; x++) row[x] = (byte)(255 - row[x]);
        }
    }

    /// <summary>Box blur with edge replication, <paramref name="passes"/> times, on a W*H grid.</summary>
    private static void BoxBlurGrid(int[] a, int w, int h, int radius, int passes)
    {
        if (radius < 1 || w < 1 || h < 1) return;
        var tmp = new int[w * h];
        int window = 2 * radius + 1;
        static int Clamp(int v, int hi) => v < 0 ? 0 : v > hi ? hi : v;
        for (int pass = 0; pass < passes; pass++)
        {
            for (int y = 0; y < h; y++)
            {
                int sum = 0;
                for (int i = -radius; i <= radius; i++) sum += a[y * w + Clamp(i, w - 1)];
                for (int x = 0; x < w; x++)
                {
                    tmp[y * w + x] = sum / window;
                    sum += a[y * w + Clamp(x + radius + 1, w - 1)] - a[y * w + Clamp(x - radius, w - 1)];
                }
            }
            for (int x = 0; x < w; x++)
            {
                int sum = 0;
                for (int i = -radius; i <= radius; i++) sum += tmp[Clamp(i, h - 1) * w + x];
                for (int y = 0; y < h; y++)
                {
                    a[y * w + x] = sum / window;
                    sum += tmp[Clamp(y + radius + 1, h - 1) * w + x] - tmp[Clamp(y - radius, h - 1) * w + x];
                }
            }
        }
    }

    /// <summary>Low-resolution map of a per-region value (8.8 fixed point), sampled back bilinearly.</summary>
    private sealed class LowResMap
    {
        public readonly int W, H, Cell;
        public int[] V;
        private readonly int[] _xIdx, _xWgt, _rowTmp;

        public LowResMap(int width, int height, int cell)
        {
            if (cell < 1) cell = 1;
            Cell = cell;
            W = (width + cell - 1) / cell;
            H = (height + cell - 1) / cell;
            V = new int[W * H];
            _xIdx = new int[width];
            _xWgt = new int[width];
            _rowTmp = new int[W];
            // Cell centres sit at (i + 0.5) * Cell. fx is the position in cells, 8.8.
            for (int x = 0; x < width; x++)
            {
                int fx = ((2 * x + 1) * 128) / cell - 128;
                if (fx < 0) fx = 0;
                int i0 = fx >> 8;
                if (i0 >= W - 1)
                {
                    _xIdx[x] = Math.Max(0, W - 2);
                    _xWgt[x] = W > 1 ? 256 : 0;
                }
                else
                {
                    _xIdx[x] = i0;
                    _xWgt[x] = fx & 255;
                }
            }
        }

        /// <summary>Fills row[0..width) with the map sampled along image row y (values 0..255).</summary>
        public void SampleRow(int y, int width, Span<byte> row)
        {
            int fy = ((2 * y + 1) * 128) / Cell - 128;
            if (fy < 0) fy = 0;
            int j0 = fy >> 8, j1, wy = fy & 255;
            if (j0 >= H - 1) { j0 = H - 1; j1 = j0; wy = 0; }
            else j1 = j0 + 1;
            for (int x = 0; x < W; x++)
                _rowTmp[x] = (V[j0 * W + x] * (256 - wy) + V[j1 * W + x] * wy) / 256;
            for (int x = 0; x < width; x++)
            {
                int i0 = _xIdx[x], wx = _xWgt[x];
                int i1 = W > 1 ? i0 + 1 : i0;
                int a = _rowTmp[i0], b = _rowTmp[i1];
                row[x] = ClampByte(((long)a * (256 - wx) + (long)b * wx + 32768) >> 16);
            }
        }
    }

    // ------------------------------------------------------------ auto levels

    /// <summary>
    /// Stretches the frame so its darkest and brightest content use the full range.
    /// Statistics come from the central 80% so film borders do not decide the result.
    /// Strength = share clipped at each end (0 = none, 100 = 2%); stretch limited to ~4x.
    /// </summary>
    internal static void AutoLevelsGray(Span<byte> data, int width, int height, int stride, int strength)
    {
        const int MinRange = 64;
        var hist = new long[256];
        int x0 = width / 10, x1 = width - x0, y0 = height / 10, y1 = height - y0;
        if (x1 - x0 < 8 || y1 - y0 < 8) { x0 = 0; x1 = width; y0 = 0; y1 = height; }
        for (int y = y0; y < y1; y++)
        {
            var row = data.Slice(y * stride + x0, x1 - x0);
            foreach (byte b in row) hist[b]++;
        }
        long total = (long)(x1 - x0) * (y1 - y0);
        long clipCount = total * strength / 5000;

        int lo = 0; long acc = 0;
        while (lo < 255) { acc += hist[lo]; if (acc > clipCount) break; lo++; }
        int hi = 255; acc = 0;
        while (hi > 0) { acc += hist[hi]; if (acc > clipCount) break; hi--; }

        if (hi - lo < MinRange)
        {
            int mid = (lo + hi) / 2;
            lo = mid - MinRange / 2;
            hi = lo + MinRange;
            if (lo < 0) { lo = 0; hi = MinRange; }
            else if (hi > 255) { hi = 255; lo = 255 - MinRange; }
        }
        if (lo == 0 && hi == 255) return;

        var lut = new byte[256];
        for (int v = 0; v < 256; v++) lut[v] = ClampByte(((v - lo) * 255 + (hi - lo) / 2) / (hi - lo));
        ApplyLut(data, width, height, stride, lut);
    }

    // ------------------------------------------------------------ CLAHE

    /// <summary>
    /// Contrast-limited adaptive histogram equalisation: per-tile equalising curves,
    /// blended between tile centres. Strength sets the clip limit (0 = none, 100 = strongest).
    /// </summary>
    internal static void ClaheGray(Span<byte> data, int width, int height, int stride, int strength)
    {
        if (strength <= 0 || width < 16 || height < 16) return;
        if (strength > 100) strength = 100;

        int tileSize = Math.Max(32, Math.Min(width, height) / 8);
        int tx = Math.Max(1, Math.Min(32, (width + tileSize / 2) / tileSize));
        int ty = Math.Max(1, Math.Min(32, (height + tileSize / 2) / tileSize));
        double clipFactor = 1.0 + strength * 0.03;

        var maps = new byte[tx * ty][];
        var hist = new int[256];
        for (int j = 0; j < ty; j++)
        {
            int y0 = (int)((long)j * height / ty), y1 = (int)((long)(j + 1) * height / ty);
            for (int i = 0; i < tx; i++)
            {
                int x0 = (int)((long)i * width / tx), x1 = (int)((long)(i + 1) * width / tx);
                var map = maps[j * tx + i] = new byte[256];
                Array.Clear(hist);
                for (int y = y0; y < y1; y++)
                    foreach (byte b in data.Slice(y * stride + x0, x1 - x0)) hist[b]++;
                int n = (x1 - x0) * (y1 - y0);
                if (n <= 0)
                {
                    for (int v = 0; v < 256; v++) map[v] = (byte)v;
                    continue;
                }

                int clip = Math.Max(1, (int)Math.Round(clipFactor * n / 256.0));
                int excess = 0;
                for (int v = 0; v < 256; v++)
                    if (hist[v] > clip) { excess += hist[v] - clip; hist[v] = clip; }
                int add = excess / 256, rest = excess - add * 256;
                for (int v = 0; v < 256; v++) hist[v] += add;
                if (rest > 0)
                {
                    int step = Math.Max(1, 256 / rest);
                    for (int v = 0; v < 256 && rest > 0; v += step) { hist[v]++; rest--; }
                }

                int accum = 0;
                for (int v = 0; v < 256; v++)
                {
                    accum += hist[v];
                    map[v] = ClampByte(((long)accum * 255 + n / 2) / n);
                }
            }
        }

        // Per-column tile indices and blend weights (0..256).
        var colI0 = new int[width]; var colI1 = new int[width]; var colW = new int[width];
        for (int x = 0; x < width; x++)
        {
            int fx = (int)(((long)(2 * x + 1) * tx * 128) / width) - 128;
            if (fx < 0) fx = 0;
            int i = fx >> 8;
            if (i >= tx - 1) { colI0[x] = tx - 1; colI1[x] = tx - 1; colW[x] = 0; }
            else { colI0[x] = i; colI1[x] = i + 1; colW[x] = fx & 255; }
        }

        for (int y = 0; y < height; y++)
        {
            int fy = (int)(((long)(2 * y + 1) * ty * 128) / height) - 128;
            if (fy < 0) fy = 0;
            int j = fy >> 8, rowJ0, rowJ1, wy;
            if (j >= ty - 1) { rowJ0 = ty - 1; rowJ1 = ty - 1; wy = 0; }
            else { rowJ0 = j; rowJ1 = j + 1; wy = fy & 255; }
            var row = data.Slice(y * stride, width);
            for (int x = 0; x < width; x++)
            {
                int v = row[x], wx = colW[x];
                byte[] m00 = maps[rowJ0 * tx + colI0[x]], m01 = maps[rowJ0 * tx + colI1[x]];
                byte[] m10 = maps[rowJ1 * tx + colI0[x]], m11 = maps[rowJ1 * tx + colI1[x]];
                row[x] = (byte)(((m00[v] * (256 - wx) + m01[v] * wx) * (256 - wy) +
                                 (m10[v] * (256 - wx) + m11[v] * wx) * wy + 32768) >> 16);
            }
        }
    }

    // ------------------------------------------------------------ exposure balance

    /// <summary>
    /// Local gamma correction: dark neighbourhoods are brightened and bright ones darkened.
    /// For frames under-exposed in one part and over-exposed in another.
    /// Strength: 0 = none, 50 = classic, 100 = strongest.
    /// </summary>
    internal static void LocalExposureGray(Span<byte> data, int width, int height, int stride, int strength)
    {
        if (strength <= 0 || width < 8 || height < 8) return;
        if (strength > 100) strength = 100;

        int cell = Math.Max(1, Math.Min(width, height) / 128);
        var map = new LowResMap(width, height, cell);
        for (int cy = 0; cy < map.H; cy++)
        {
            int y0 = cy * cell, y1 = Math.Min(height, y0 + cell);
            for (int cx = 0; cx < map.W; cx++)
            {
                int x0 = cx * cell, x1 = Math.Min(width, x0 + cell);
                long sum = 0;
                for (int y = y0; y < y1; y++)
                    foreach (byte b in data.Slice(y * stride + x0, x1 - x0)) sum += b;
                map.V[cy * map.W + cx] = (int)(sum * 256 / ((long)(x1 - x0) * (y1 - y0)));
            }
        }
        int radius = Math.Max(1, Math.Min(map.W, map.H) / 16);
        BoxBlurGrid(map.V, map.W, map.H, radius, 3);

        double a = strength / 50.0;
        var table = new byte[256 * 256]; // [mean][value]
        for (int m = 0; m < 256; m++)
        {
            double expo = Math.Pow(2.0, a * (2.0 * m / 255.0 - 1.0));
            table[m * 256] = 0;
            for (int v = 1; v < 256; v++)
                table[m * 256 + v] = ClampByte(255.0 * Math.Pow(v / 255.0, expo));
        }

        var meanRow = new byte[width];
        for (int y = 0; y < height; y++)
        {
            map.SampleRow(y, width, meanRow);
            var row = data.Slice(y * stride, width);
            for (int x = 0; x < width; x++) row[x] = table[meanRow[x] * 256 + row[x]];
        }
    }

    // ------------------------------------------------------------ background flatten

    /// <summary>
    /// Estimates the paper brightness in each part of the frame and divides it out, so
    /// unevenly lit pages get an even, light background. Strength: 0 = none, 100 = full.
    /// </summary>
    internal static void BackgroundFlattenGray(Span<byte> data, int width, int height, int stride, int strength)
    {
        const int TargetBg = 240;
        const double MaxGain = 6.0;
        const int NoPaperBelow = 24;   // darker: film border, leave alone
        const int FullGainFrom = 48;   // from here up: full correction

        if (strength <= 0 || width < 16 || height < 16) return;
        if (strength > 100) strength = 100;

        int cell = Math.Max(4, Math.Min(width, height) / 48);
        var map = new LowResMap(width, height, cell);
        var hist = new int[256];
        for (int cy = 0; cy < map.H; cy++)
        {
            int y0 = cy * cell, y1 = Math.Min(height, y0 + cell);
            for (int cx = 0; cx < map.W; cx++)
            {
                int x0 = cx * cell, x1 = Math.Min(width, x0 + cell);
                Array.Clear(hist);
                for (int y = y0; y < y1; y++)
                    foreach (byte b in data.Slice(y * stride + x0, x1 - x0)) hist[b]++;
                // 90th percentile: the paper level, ignoring ink and specks.
                int need = ((x1 - x0) * (y1 - y0)) / 10, acc = 0, v = 255;
                while (v > 0) { acc += hist[v]; if (acc > need) break; v--; }
                map.V[cy * map.W + cx] = v * 256;
            }
        }

        // A cell fully covered by dark content has no paper: borrow the brightest neighbour.
        var dilated = new int[map.W * map.H];
        for (int cy = 0; cy < map.H; cy++)
            for (int cx = 0; cx < map.W; cx++)
            {
                int best = 0;
                for (int dy = -2; dy <= 2; dy++)
                    for (int dx = -2; dx <= 2; dx++)
                        if (cx + dx >= 0 && cx + dx < map.W && cy + dy >= 0 && cy + dy < map.H)
                            best = Math.Max(best, map.V[(cy + dy) * map.W + cx + dx]);
                dilated[cy * map.W + cx] = best;
            }
        map.V = dilated;
        BoxBlurGrid(map.V, map.W, map.H, 2, 2);

        double s = strength / 100.0;
        var gainFix = new int[256]; // 16.16 fixed gain per background level
        for (int b = 0; b < 256; b++)
        {
            double gain;
            if (b <= NoPaperBelow) gain = 1.0;
            else
            {
                gain = (double)TargetBg / b;
                if (gain > MaxGain) gain = MaxGain;
                if (b < FullGainFrom)
                    gain = 1.0 + (gain - 1.0) * (b - NoPaperBelow) / (FullGainFrom - NoPaperBelow);
            }
            gain = 1.0 + (gain - 1.0) * s;
            gainFix[b] = (int)Math.Round(gain * 65536.0);
        }

        var bgRow = new byte[width];
        for (int y = 0; y < height; y++)
        {
            map.SampleRow(y, width, bgRow);
            var row = data.Slice(y * stride, width);
            for (int x = 0; x < width; x++)
            {
                long v = ((long)row[x] * gainFix[bgRow[x]] + 32768) >> 16;
                row[x] = v > 255 ? (byte)255 : (byte)v;
            }
        }
    }
}

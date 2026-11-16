using System.Globalization;
using System.Text;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Demo;

/// <summary>
/// Writes a small synthetic roll (IDF + full strips + previews) so the app can be tried
/// without real scans. Pages vary in exposure so the tone methods have something to fix,
/// and a few pages cross strip boundaries like real film.
/// </summary>
public static class DemoRoll
{
    public const int StripCount = 24;
    public const int LengthLines = 1600;  // along the film, per strip
    public const int WidthPixels = 1400;  // across the film
    public const int DownScale = 8;

    /// <summary>Creates the roll in <paramref name="folder"/> (if not there yet) and returns the IDF path.</summary>
    public static string Create(string folder)
    {
        string idf = Path.Combine(folder, "DEMO_ROLL.idf");
        string stamp = Path.Combine(folder, ".demo-v2"); // bump when the generated images change
        if (File.Exists(idf) && File.Exists(stamp)) return idf;

        Directory.CreateDirectory(Path.Combine(folder, "strips"));
        Directory.CreateDirectory(Path.Combine(folder, "previews"));

        var pages = Layout();
        var rng = new Random(42);

        for (int s = 0; s < StripCount; s++)
        {
            // Strips are stored on their side: image width = across, height = along.
            var strip = new GrayImage(WidthPixels, LengthLines);
            long stripStart = (long)s * LengthLines;
            var d = strip.Data;
            for (int i = 0; i < d.Length; i++) d[i] = (byte)(18 + rng.Next(10)); // film base + grain

            foreach (var p in pages)
            {
                long a = Math.Max(p.Lead, stripStart), b = Math.Min(p.Trail, stripStart + LengthLines);
                if (b <= a) continue;
                for (long line = a; line < b; line++)
                {
                    int y = (int)(line - stripStart);
                    double t = (line - p.Lead) / (double)(p.Trail - p.Lead); // 0..1 down the page
                    for (int x = p.Left; x < p.Right; x++)
                    {
                        double u = (x - p.Left) / (double)(p.Right - p.Left);
                        double paper = p.Paper + p.Vignette * (u - 0.5) * 2; // uneven lighting
                        // Lines of "text" run along the film, so the page reads upright once the strip is
                        // turned (CCW: the far edge across the film becomes the top of the page).
                        bool ink = IsInk(1 - u, t, p.Seed);
                        double v = ink ? paper * 0.28 : paper;
                        d[y * WidthPixels + x] = (byte)Math.Clamp(v + rng.Next(-6, 7), 0, 255);
                    }
                }
            }

            var full = TurboJpeg.EncodeGray(strip, 90, false);
            File.WriteAllBytes(Path.Combine(folder, "strips", $"strip{RollPaths.ZeroPad(s + 1, 9)}.jpg"), full);
            var preview = strip.Downscale(DownScale);
            File.WriteAllBytes(Path.Combine(folder, "previews", $"preview{RollPaths.ZeroPad(s + 1, 9)}.jpg"),
                TurboJpeg.EncodeGray(preview, 92, false));
        }

        File.WriteAllText(idf, Idf(pages), new UTF8Encoding(false));
        File.WriteAllText(stamp, "");
        return idf;
    }

    private sealed record Page(long Lead, long Trail, int Left, int Right, double Paper, double Vignette, int Seed);

    private static List<Page> Layout()
    {
        var pages = new List<Page>();
        var rng = new Random(7);
        long pos = 180;
        long end = (long)StripCount * LengthLines - 200;
        int n = 0;
        while (true)
        {
            int len = 980 + rng.Next(-60, 60);
            if (n % 11 == 7) len += 520; // the odd oversized page
            if (pos + len > end) break;
            int left = 140 + rng.Next(-30, 30), right = WidthPixels - 140 + rng.Next(-30, 30);
            double paper = (n % 6) switch { 2 => 120, 4 => 250, _ => 205 }; // dark, bright, normal
            double vignette = n % 5 == 3 ? 55 : 8;
            pages.Add(new Page(pos, pos + len, left, right, paper, vignette, n));
            pos += len + 230 + rng.Next(0, 80);
            n++;
        }
        return pages;
    }

    /// <summary>Cheap "document" look: title bar, text lines with ragged ends, a box.</summary>
    private static bool IsInk(double t, double u, int seed)
    {
        if (t < 0.05 || t > 0.95 || u < 0.07 || u > 0.93) return false;
        if (t > 0.08 && t < 0.13) return u > 0.2 && u < 0.8 && (int)(u * 60) % 3 != 0; // heading
        if (t > 0.70 && t < 0.86 && u > 0.55 && u < 0.88)
            return t < 0.705 || t > 0.855 || u < 0.555 || u > 0.875;                // stamp box
        double row = (t - 0.18) / 0.028;
        if (row < 0 || t > 0.66) return false;
        int r = (int)row;
        double frac = row - r;
        if (frac > 0.38) return false;
        double lineEnd = 0.55 + ((r * 37 + seed * 13) % 37) / 100.0;
        return u < lineEnd && (int)(u * 90 + r) % 7 != 0;
    }

    private static string Idf(List<Page> pages)
    {
        var sb = new StringBuilder();
        string I(long v) => v.ToString(CultureInfo.InvariantCulture);
        sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n");
        sb.Append("<Roll RollName=\"DEMO_ROLL\" RollNumber=\"1\" RollID=\"DEMO-0001\">\r\n");
        sb.Append($"  <ScannerSettings StripCount=\"{StripCount}\" DPI=\"300\" WidthPixels=\"{WidthPixels}\" LengthLines=\"{LengthLines}\" ")
          .Append($"StripPreviewDownScale=\"{DownScale}\" StripImageFolder=\"strips\" StripPreviewImageFolder=\"previews\" ")
          .Append("StripImageFilePrefix=\"strip\" StripPreviewImageFilePrefix=\"preview\" StripImageFileDigits=\"9\" JpgQuality=\"90\">\r\n");
        sb.Append("    <DetectionSettings DetectionThreshold=\"100\" DetectMinWidth=\"252\" DetectMinLength=\"252\">\r\n");
        foreach (var p in pages)
            sb.Append($"      <Frame LeadEdge=\"{I(p.Lead - 20)}\" TrailEdge=\"{I(p.Trail + 20)}\" LeftEdge=\"{I(p.Left - 20)}\" RightEdge=\"{I(p.Right + 20)}\" />\r\n");
        sb.Append("    </DetectionSettings>\r\n  </ScannerSettings>\r\n</Roll>\r\n");
        return sb.ToString();
    }
}

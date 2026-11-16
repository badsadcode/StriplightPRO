using Striplight.Core.Detection;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

/// <summary>QuantumScan-style advanced detection controls.</summary>
public class DetectionAdvancedTests
{
    // Preview = full resolution / 4: 100 px across, 200 lines along.
    private static readonly RollData Roll = new() { Loaded = true, StripCount = 1, LengthLines = 800, WidthPixels = 400, PreviewDownScale = 4 };
    private const int W = 100, H = 200;

    private static DecodedImage Page(byte background = 0)
    {
        var px = new byte[W * H];
        Array.Fill(px, background);
        return new DecodedImage(W, H, 1, px);
    }

    private static void Fill(DecodedImage img, int x0, int x1, int y0, int y1, byte v)
    {
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) img.Pixels[y * W + x] = v;
    }

    private static List<FrameRecord> Detect(DecodedImage img, DetectOptions? o = null) =>
        FrameDetector.Detect(Roll, (o ?? new DetectOptions()) with { StripFrom = 0, StripTo = 0, MinWidthPx = 100, MinHeightPx = 100, Threshold = 100 },
            _ => img);

    [Fact]
    public void MinRunLengthIgnoresSpecksThatWidenTheFrame()
    {
        var img = Page();
        Fill(img, 30, 70, 20, 120, 220);
        for (int y = 20; y < 120; y += 3) img.Pixels[y * W + 95] = 255;   // dust specks at the film edge

        Assert.Equal(384, Detect(img)[0].RightEdge);                          // speck widens the box
        var clean = Detect(img, new DetectOptions { MinRunPx = 12 })[0];      // 3 preview px
        Assert.Equal((120, 280), (clean.LeftEdge, clean.RightEdge));
    }

    [Fact]
    public void TouchLengthKeepsAFrameWithADarkLineInOnePiece()
    {
        var img = Page();
        Fill(img, 20, 80, 20, 90, 220);
        Fill(img, 20, 80, 94, 160, 220);   // 4 dark lines in the middle of the page

        Assert.Equal(2, Detect(img).Count);
        Assert.Single(Detect(img, new DetectOptions { MergeAcrossGaps = 32 }));   // 8 preview lines
    }

    [Fact]
    public void MaximumLengthSplitsAndOverscanGrows()
    {
        var img = Page();
        Fill(img, 20, 80, 10, 190, 220);   // one long frame: lines 40..760
        var parts = Detect(img, new DetectOptions { MaxLengthPx = 300 });
        Assert.Equal(3, parts.Count);
        Assert.Equal((40L, 280L), (parts[0].LeadEdge, parts[0].TrailEdge));
        Assert.Equal(760L, parts[2].TrailEdge);

        var grown = Detect(img, new DetectOptions { OverscanWidthPx = 20, OverscanLengthPx = 50 })[0];
        Assert.Equal((0L, 800L, 60, 340), (grown.LeadEdge, grown.TrailEdge, grown.LeftEdge, grown.RightEdge));
    }

    [Fact]
    public void InvertFindsDarkFramesOnLightFilm()
    {
        var img = Page(230);
        Fill(img, 20, 80, 20, 120, 10);
        Assert.DoesNotContain(Detect(img), f => f.Width < 400);
        var f = Detect(img, new DetectOptions { Invert = true })[0];
        Assert.Equal((80L, 480L, 80, 320), (f.LeadEdge, f.TrailEdge, f.LeftEdge, f.RightEdge));
    }

    [Fact]
    public void AutoThresholdSeparatesGreyPagesFromGreyBackground()
    {
        // Pages at 150 on a grey copy stand at 110: threshold 100 sees one big blob.
        var img = Page(110);
        Fill(img, 20, 80, 20, 90, 150);
        Fill(img, 20, 80, 110, 180, 150);
        Assert.Single(Detect(img));
        var auto = Detect(img, new DetectOptions { AutoThreshold = true });
        Assert.Equal(2, auto.Count);
        Assert.Equal((80, 320), (auto[0].LeftEdge, auto[0].RightEdge));
    }

    [Fact]
    public void AutoThresholdFallsBackOnEmptyFilm()
    {
        var hist = new long[256];
        hist[5] = 1000; hist[8] = 900;    // just film, no frames
        Assert.Equal(-1, FrameDetector.OtsuThreshold(hist));
    }
}

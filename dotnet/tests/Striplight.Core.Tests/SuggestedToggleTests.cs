using Striplight.Core.Editing;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public class SuggestedToggleTests
{
    private static List<FrameRecord> Frames(int n) =>
        Enumerable.Range(0, n).Select(i => new FrameRecord { LeadEdge = i * 100, TrailEdge = i * 100 + 80, RightEdge = 50 }).ToList();

    [Fact]
    public void ManyFramesToggleLikeFolderMarkers()
    {
        var f = Frames(5);
        f[1].IsSuggested = true;
        FrameEditor.ToggleSuggested(f, [1, 2, 3]);               // not all suggested → all set
        Assert.Equal([false, true, true, true, false], f.Select(x => x.IsSuggested));
        FrameEditor.ToggleSuggested(f, [1, 2, 3]);               // all suggested → all cleared
        Assert.DoesNotContain(f, x => x.IsSuggested);
    }

    [Fact]
    public void FolderAndSuggestedSections()
    {
        var f = Frames(10);
        f[1].IsMarker = true; f[4].IsSuggested = true; f[7].IsMarker = true;
        Assert.Equal((1, 6), FrameRepair.Section(f, 5, includeSuggested: false));   // yellow to yellow
        Assert.Equal((4, 6), FrameRepair.Section(f, 5, includeSuggested: true));    // purple to next start
        Assert.Equal((1, 3), FrameRepair.Section(f, 2, includeSuggested: true));
    }
}

public class FillGapsLimitTests
{
    // Tom's sketch: pages 1-2-3 close together, a big gap, 4-5-6, a big gap, 7.
    private static List<FrameRecord> Sketch()
    {
        long[] leads = [0, 1100, 2200, 3900, 5000, 6100, 7800];
        return leads.Select(l => new FrameRecord { LeadEdge = l, TrailEdge = l + 1000, LeftEdge = 0, RightEdge = 900 }).ToList();
    }

    [Fact]
    public void AutoFillsTheNormalGapsAndSkipsTheBigOnes()
    {
        var f = Sketch();
        int[] all = [0, 1, 2, 3, 4, 5, 6];
        long limit = FrameRepair.AutoGapLimit(f, all, 2.0);           // typical gap 100 → limit 200 (floor 100)
        Assert.Equal(200, limit);
        var (changed, skipped, _) = FrameRepair.CloseGaps(f, all, limit);
        Assert.Equal((4, 2), (changed, skipped));
        Assert.Equal(f[1].LeadEdge, f[0].TrailEdge);                  // 1-2 filled
        Assert.Equal(f[2].LeadEdge, f[1].TrailEdge);                  // 2-3 filled
        Assert.Equal((3200L, 3900L), (f[2].TrailEdge, f[3].LeadEdge)); // 3-4 untouched
        Assert.Equal((7100L, 7800L), (f[5].TrailEdge, f[6].LeadEdge)); // 6-7 untouched
    }

    [Fact]
    public void WithoutALimitEveryGapIsFilledAsBefore()
    {
        var f = Sketch();
        var (changed, skipped, _) = FrameRepair.CloseGaps(f, [0, 1, 2, 3, 4, 5, 6], long.MaxValue);
        Assert.Equal((6, 0), (changed, skipped));
    }

    [Fact]
    public void TouchingPagesStillCountAsNormal()
    {
        long[] leads = [0, 1002, 2004, 3700];                          // 2-line gaps, then a big one
        var f = leads.Select(l => new FrameRecord { LeadEdge = l, TrailEdge = l + 1000, RightEdge = 900 }).ToList();
        long limit = FrameRepair.AutoGapLimit(f, [0, 1, 2, 3], 2.0);
        Assert.Equal(100, limit);                                      // floor: 10 % of the frame length
        var (changed, skipped, _) = FrameRepair.CloseGaps(f, [0, 1, 2, 3], limit);
        Assert.Equal((2, 1), (changed, skipped));
    }
}

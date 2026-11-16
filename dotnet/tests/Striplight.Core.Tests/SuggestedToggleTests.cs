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

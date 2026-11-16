using Striplight.Core.Editing;
using Striplight.Core.Export;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public class SizeRuleTests
{
    private static List<FrameRecord> Frames(params long[] lengths)
    {
        long at = 0;
        var list = new List<FrameRecord>();
        foreach (long len in lengths)
        {
            list.Add(new FrameRecord { LeadEdge = at, TrailEdge = at + len, LeftEdge = 0, RightEdge = 100 });
            at += len + 50;
        }
        return list;
    }

    [Fact]
    public void PercentAboveAndBelowTheMedian()
    {
        try
        {
            var f = Frames(1000, 1000, 1000, 1400, 1600, 700, 400);   // median 1000
            FrameEditor.SetSizeRules(true, 50, true, 50);            // > 1500 big, < 500 small
            FrameEditor.Refresh(f);
            Assert.Equal([false, false, false, false, true, false, false], f.Select(x => x.IsOversized));
            Assert.Equal([false, false, false, false, false, false, true], f.Select(x => x.IsUndersized));

            FrameEditor.SetSizeRules(true, 30, true, 20);            // > 1300 big, < 800 small
            FrameEditor.Refresh(f);
            Assert.Equal(2, f.Count(x => x.IsOversized));
            Assert.Equal(2, f.Count(x => x.IsUndersized));

            FrameEditor.SetSizeRules(false, 30, false, 20);          // both checks off
            FrameEditor.Refresh(f);
            Assert.DoesNotContain(f, x => x.IsOversized || x.IsUndersized);
        }
        finally { FrameEditor.SetSizeRules(true, 50, true, 50); }
    }
}

public class ArchiveFolderTests
{
    [Fact]
    public void OneRowPerLeafFolderInNaturalOrder()
    {
        using var t = new TempDir();
        string root = t.File("archive");
        foreach (string p in new[] { "73/524/0/0/80", "73/524/0/0/10", "73/524/0/0/9", "73/525/1", "bad;name/x", "73/524/0/0/80/" })
            Directory.CreateDirectory(Path.Combine(root, p));

        var r = ArchiveFolders.Build(root);
        Assert.Equal([";73;524;0;0;9", ";73;524;0;0;10", ";73;524;0;0;80", ";73;525;1"], r.Rows);
        Assert.Equal(1, r.SkippedNames);
    }

    [Fact]
    public void NaturalCompareTreatsDigitRunsAsNumbers()
    {
        var names = new List<string> { "Box 10", "box 2", "Box 1", "Box 02a" };
        names.Sort(ArchiveFolders.NaturalCompare);
        Assert.Equal(["Box 1", "box 2", "Box 02a", "Box 10"], names);
    }
}

using Striplight.Core.IO;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public class PreviewCacheTests
{
    private static RollData Roll(string baseDir, int strips)
    {
        var roll = new RollData
        {
            Loaded = true, StripCount = strips, RollName = "R 0042", BasePath = baseDir + Path.DirectorySeparatorChar,
            PreviewBasePath = baseDir + Path.DirectorySeparatorChar, PreviewFolder = "previews", PreviewPrefix = "preview", StripDigits = 9,
        };
        Directory.CreateDirectory(Path.Combine(baseDir, "previews"));
        for (int i = 0; i < strips; i++) File.WriteAllBytes(RollPaths.PreviewSourcePath(roll, i), [1, 2, (byte)i]);
        return roll;
    }

    [Fact]
    public void FirstUseCopiesIntoTheCacheAndDisableGoesBack()
    {
        using var t = new TempDir();
        var roll = Roll(t.File("share"), 3);
        string root = PreviewCache.ProjectRoot(t.File("cache"), roll, t.File("share/R 0042.idf"));
        Assert.StartsWith("R_0042_", Path.GetFileName(root));

        PreviewCache.Enable(roll, root);
        string p = RollPaths.PreviewFilePath(roll, 1);
        Assert.StartsWith(root, p);
        Assert.Equal(new byte[] { 1, 2, 1 }, File.ReadAllBytes(p));
        Assert.Equal((1, 3), PreviewCache.Count(roll, root));
        Assert.Empty(Directory.GetFiles(Path.Combine(root, "previews"), "*.part"));

        PreviewCache.Disable(roll);
        Assert.StartsWith(t.File("share"), RollPaths.PreviewFilePath(roll, 1));
    }

    [Fact]
    public void BackgroundCacheCopiesWhatIsMissingAndCountsTheRest()
    {
        using var t = new TempDir();
        var roll = Roll(t.File("share"), 5);
        File.Delete(RollPaths.PreviewSourcePath(roll, 4));          // one preview missing at the source
        string root = PreviewCache.ProjectRoot(t.File("cache"), roll, "");
        PreviewCache.Enable(roll, root);
        RollPaths.PreviewFilePath(roll, 0);                          // already cached by use
        var r = PreviewCache.CacheRoll(roll, root, "R0042");
        Assert.Equal((3, 1, 1, false), (r.Copied, r.Skipped, r.Missing, r.Cancelled));
        Assert.Equal((4, 5), PreviewCache.Count(roll, root));
        Assert.True(PreviewCache.SizeBytes(root) > 0);
    }

    [Fact]
    public void SameNameDifferentSourceGetsItsOwnFolder()
    {
        using var t = new TempDir();
        var a = Roll(t.File("a"), 1);
        var b = Roll(t.File("b"), 1);
        a.RollName = b.RollName = "same";
        Assert.NotEqual(PreviewCache.ProjectRoot(t.File("c"), a, ""), PreviewCache.ProjectRoot(t.File("c"), b, ""));
    }

    [Fact]
    public void ClearOnlyDeletesInsideTheCacheRoot()
    {
        using var t = new TempDir();
        Directory.CreateDirectory(t.File("cache/x/previews"));
        Directory.CreateDirectory(t.File("precious"));
        Assert.False(PreviewCache.Clear(t.File("precious"), t.File("cache")));
        Assert.True(Directory.Exists(t.File("precious")));
        Assert.True(PreviewCache.Clear(t.File("cache/x"), t.File("cache")));
        Assert.False(Directory.Exists(t.File("cache/x")));
    }
}

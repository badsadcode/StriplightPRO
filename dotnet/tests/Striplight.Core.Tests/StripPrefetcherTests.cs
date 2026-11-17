using System.Collections.Concurrent;
using Striplight.Core.Export;

namespace Striplight.Core.Tests;

public class StripPrefetcherTests
{
    [Fact]
    public void ReadsAheadInOrderAndEveryFileOnce()
    {
        var reads = new ConcurrentQueue<string>();
        byte[] Read(string x) { reads.Enqueue(x); Thread.Sleep(20); return [(byte)x[1]]; }
        var paths = new[] { "s1", "s2", "s2", "s3", "s4", "s5", "s6" };
        using var p = new StripPrefetcher(paths, ahead: 2, readers: 2, read: Read);

        Thread.Sleep(300);                        // only the window is fetched before anyone asks
        Assert.True(reads.Count <= 3);
        // Like the export: a file the read-ahead has not scheduled yet is read by the worker itself.
        foreach (string s in new[] { "s1", "s2", "s3", "s4", "s5", "s6" })
            Assert.Equal((byte)s[1], (p.Take(s) ?? Read(s))[0]);
        Assert.Equal(6, reads.Count);             // s2 listed twice, read once
        Assert.Equal(6, reads.Distinct().Count());
        Assert.Null(p.Take("s3"));                // handed out once; a second use reads the file again
    }

    [Fact]
    public void UnknownOrFailedFilesFallBackToTheCaller()
    {
        using var p = new StripPrefetcher(["a", "b"], read: x => x == "b" ? throw new IOException("share gone") : [1]);
        Assert.Null(p.Take("zzz"));
        Assert.NotNull(p.Take("a"));
        Assert.Null(p.Take("b"));                 // failed read: the worker tries itself and reports the error
    }

    [Fact]
    public void SkipsWhatTheWorkersAlreadyPassed()
    {
        var reads = new ConcurrentQueue<string>();
        var paths = Enumerable.Range(0, 20).Select(i => "p" + i).ToArray();
        using var p = new StripPrefetcher(paths, ahead: 2, readers: 1, read: x => { reads.Enqueue(x); return [0]; });
        Thread.Sleep(100);
        p.Take("p15");                            // workers jumped ahead (e.g. skip existing files)
        Thread.Sleep(200);
        Assert.DoesNotContain(reads, r => r is "p5" or "p10" or "p14");
        Assert.Contains("p16", reads);
    }
}

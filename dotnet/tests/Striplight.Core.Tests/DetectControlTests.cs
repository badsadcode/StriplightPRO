using Striplight.Core.Detection;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public class DetectControlTests
{
    private sealed class SyncProgress(Action<DetectProgress> a) : IProgress<DetectProgress>
    {
        public void Report(DetectProgress p) => a(p);
    }

    // 3 strips of 200 preview lines (800 full-res lines each, downscale 4), 100 px across.
    private static readonly RollData Roll = new() { Loaded = true, StripCount = 3, LengthLines = 800, WidthPixels = 400, PreviewDownScale = 4 };

    private static DecodedImage Strip(int s)
    {
        var px = new byte[100 * 200];
        void Fill(int y0, int y1) { for (int y = y0; y < y1; y++) for (int x = 10; x < 90; x++) px[y * 100 + x] = 220; }
        if (s == 0) { Fill(20, 90); Fill(140, 200); }   // a frame, then one that runs into strip 1
        if (s == 1) { Fill(0, 50); Fill(100, 170); }
        if (s == 2) Fill(30, 120);
        return new DecodedImage(100, 200, 1, px);
    }

    private static readonly DetectOptions Opt = new() { StripFrom = 0, StripTo = 2, MinWidthPx = 100, MinHeightPx = 100, Threshold = 100, MergeAcrossGaps = 16 };

    [Fact]
    public void WholeRunFindsFourFrames()
    {
        var all = FrameDetector.Detect(Roll, Opt, Strip);
        Assert.Equal(4, all.Count);
        Assert.Equal((560L, 1000L), (all[1].LeadEdge, all[1].TrailEdge));   // crosses strips 0 → 1
    }

    [Fact]
    public void StopKeepsFramesAndContinueFinishesTheOpenFrame()
    {
        var control = new DetectControl();
        var first = FrameDetector.Detect(Roll, Opt, Strip, new SyncProgress(p => { if (p.StripIndex == 0) control.Stop(); }), default, control);

        Assert.Equal(0, control.LastStrip);
        Assert.Equal(2, first.Count);                       // kept, not thrown away
        Assert.NotNull(control.OpenFrame);                  // the frame running into strip 1
        Assert.Equal(800L, control.OpenFrame!.TrailEdge);

        var rest = FrameDetector.Detect(Roll, Opt with { StripFrom = 1, Seed = control.OpenFrame }, Strip);
        Assert.Equal(3, rest.Count);
        Assert.Equal((560L, 1000L), (rest[0].LeadEdge, rest[0].TrailEdge));   // one frame, not two halves
    }

    [Fact]
    public void PauseHoldsTheRunUntilResumed()
    {
        var control = new DetectControl();
        control.Pause();
        var task = Task.Run(() => FrameDetector.Detect(Roll, Opt, Strip, null, default, control));
        Assert.False(task.Wait(300));
        Assert.Equal(-1, control.LastStrip);
        control.Resume();
        Assert.True(task.Wait(5000));
        Assert.Equal(4, task.Result.Count);
    }
}

using Striplight.Core.Editing;
using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.IO;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

/// <summary>Per-frame ("own") tone: locked against later changes to the global tone.</summary>
public class FrameToneTests
{
    private static ProcessSettings Global(ToneSettings t) => new() { Tone = t };

    [Fact]
    public void LockedToneIgnoresLaterGlobalChanges()
    {
        var f = new FrameRecord { LeadEdge = 0, TrailEdge = 100, LeftEdge = 0, RightEdge = 100 };
        var own = new ToneSettings(ToneMethod.Striplight, 4, 20, -10, 140, 50);
        f.LockTone(own);

        // Whatever the global tone becomes (even another method family), the frame keeps its own.
        Assert.Equal(own, FrameBuilder.Resolve(f, Global(ToneSettings.Neutral)).Tone);
        Assert.Equal(own, FrameBuilder.Resolve(f, Global(new ToneSettings(ToneMethod.Quantum, 1, 100, 50, 30, 80))).Tone);
        Assert.Equal(own, FrameBuilder.Resolve(f, Global(new ToneSettings(ToneMethod.Clahe, 0, 0, 0, 100, 90))).Tone);
        Assert.True(f.HasToneOverride);
    }

    [Fact]
    public void FramesWithoutOwnToneFollowTheGlobalTone()
    {
        var f = new FrameRecord { LeadEdge = 0, TrailEdge = 100, LeftEdge = 0, RightEdge = 100 };
        var g = new ToneSettings(ToneMethod.Quantum, 0, 90, 10, 20, 50);
        Assert.Equal(g, FrameBuilder.Resolve(f, Global(g)).Tone);

        f.LockTone(new ToneSettings(ToneMethod.Striplight, 0, 5, 5, 120, 50));
        f.ClearTone();
        Assert.False(f.HasToneOverride);
        Assert.Equal(g, FrameBuilder.Resolve(f, Global(g)).Tone);
    }

    [Fact]
    public void QuantumLockAlsoWritesQuantumScanFields()
    {
        var f = new FrameRecord();
        f.LockTone(new ToneSettings(ToneMethod.Quantum, 0, 100, 20, -30, 50));
        Assert.Equal((100, 20, -30), (f.PerFrameContrast, f.PerFrameBrightness, f.PerFrameGamma));
        f.LockTone(new ToneSettings(ToneMethod.Striplight, 0, 10, 20, 130, 50));
        Assert.Equal((-1, -1, -1), (f.PerFrameContrast, f.PerFrameBrightness, f.PerFrameGamma));
    }

    [Fact]
    public void LockedToneSurvivesSaveAndLoad()
    {
        using var t = new TempDir();
        File.WriteAllText(t.File("roll.idf"), ProjectFileTests.Idf);
        IdfParser.Parse(t.File("roll.idf"), out var roll, out var frames);
        var own = new ToneSettings(ToneMethod.Clahe, 8, 12, -4, 110, 75);
        frames[1].LockTone(own);

        string slf = t.File("roll.slf");
        ProjectFile.SaveSlf(slf, t.File("roll.idf"), new Project { Roll = roll, Frames = frames });
        Assert.True(ProjectFile.TryLoadProject(slf, out var loaded));

        Assert.False(loaded.Frames[0].HasToneOverride);
        Assert.Equal(own, FrameBuilder.Resolve(loaded.Frames[1], Global(ToneSettings.Neutral)).Tone);
    }

    [Fact]
    public void ProjectStateBlockSurvivesSaveAndLoad()
    {
        using var t = new TempDir();
        File.WriteAllText(t.File("roll.idf"), ProjectFileTests.Idf);
        IdfParser.Parse(t.File("roll.idf"), out var roll, out var frames);
        roll.StriplightState = "{\"export\":{\"outputRoot\":\"D:\\\\out\",\"prefix\":\"a]]>b\"},\"rotateCw\":true}";
        roll.ReportMicrofilm = "123-213; 400";
        string slf = t.File("roll.slf");
        ProjectFile.SaveSlf(slf, t.File("roll.idf"), new Project { Roll = roll, Frames = frames });
        Assert.True(ProjectFile.TryLoadProject(slf, out var loaded));
        Assert.Equal(roll.StriplightState, loaded.Roll.StriplightState);   // "]]>" inside survives the CDATA
        Assert.Equal("123-213; 400", loaded.Roll.ReportMicrofilm);

        // QPF (QuantumScan) never carries it
        string qpf = t.File("roll.qpf");
        ProjectFile.SaveQpf(qpf, t.File("roll.idf"), new Project { Roll = roll, Frames = frames });
        Assert.DoesNotContain("StriplightState", File.ReadAllText(qpf));
    }

    [Fact]
    public void PerFrameToneDoesNotPinTheOrientation()
    {
        using var t = new TempDir();
        File.WriteAllText(t.File("roll.idf"), ProjectFileTests.Idf);
        IdfParser.Parse(t.File("roll.idf"), out var roll, out var frames);
        frames[0].PerFrameBrightness = 12;        // QuantumScan per-frame tone
        frames[0].HasOverride = true;             // what the Lazarus edition writes for it
        frames[1].Rotation = 90; frames[1].HasOverride = true;
        string slf = t.File("roll.slf");
        ProjectFile.SaveSlf(slf, t.File("roll.idf"), new Project { Roll = roll, Frames = frames });
        Assert.True(ProjectFile.TryLoadProject(slf, out var loaded));

        Assert.False(loaded.Frames[0].HasOverride);   // follows the global orientation
        Assert.True(loaded.Frames[1].HasOverride);    // a real own orientation stays
        var global = new ProcessSettings { Rotation = 180, FlipH = true };
        Assert.Equal((180, true), (FrameBuilder.Resolve(loaded.Frames[0], global).Rotation, FrameBuilder.Resolve(loaded.Frames[0], global).FlipH));
        Assert.Equal(90, FrameBuilder.Resolve(loaded.Frames[1], global).Rotation);

        Assert.Equal(1, FrameEditor.ClearOrientation(loaded.Frames));   // "All frames follow this"
        Assert.Equal(180, FrameBuilder.Resolve(loaded.Frames[1], global).Rotation);
        Assert.Equal(12, loaded.Frames[0].PerFrameBrightness);          // tone untouched
    }
}

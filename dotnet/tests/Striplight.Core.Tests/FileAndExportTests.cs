using Striplight.Core.Detection;
using Striplight.Core.Editing;
using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.IO;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "striplight-tests-" + Guid.NewGuid().ToString("N"));
    public TempDir() => Directory.CreateDirectory(Path);
    public string File(string name) => System.IO.Path.Combine(Path, name);
    public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } }
}

public class ProjectFileTests
{
    private const string Idf = """
        <?xml version="1.0" encoding="utf-8"?>
        <Roll RollName="none" RollNumber="7" RollID="R-7">
          <StartScan />
          <ScannerSettings StripCount="3" DPI="300" WidthPixels="400" LengthLines="512"
              StripPreviewDownScale="8" StripImageFolder="strips" StripPreviewImageFolder="previews"
              StripImageFilePrefix="strip" StripPreviewImageFilePrefix="preview" StripImageFileDigits="9">
            <DetectionSettings DetectionThreshold="90">
              <Frame LeadEdge="10" TrailEdge="300" LeftEdge="20" RightEdge="380" />
              <Frame LeadEdge="400" TrailEdge="700" LeftEdge="20" RightEdge="380" />
            </DetectionSettings>
          </ScannerSettings>
        </Roll>
        """;

    [Fact]
    public void ParsesIdf()
    {
        using var t = new TempDir();
        string path = t.File("roll42.idf");
        File.WriteAllText(path, Idf);
        Assert.Equal(IdfParseResult.Ok, IdfParser.Parse(path, out var roll, out var frames));
        Assert.Equal("roll42", roll.RollName); // "none" falls back to the file name
        Assert.Equal(3, roll.StripCount);
        Assert.Equal(512, roll.LengthLines);
        Assert.Equal(8, roll.PreviewDownScale);
        Assert.Equal(90, roll.DetectionThreshold);
        Assert.Equal(2, frames.Count);
        Assert.Equal(700, frames[1].TrailEdge);
        Assert.True(frames[1].SpansStrips(roll.LengthLines));
    }

    [Fact]
    public void SlfRoundTripKeepsSettingsFramesAndNotes()
    {
        using var t = new TempDir();
        File.WriteAllText(t.File("roll.idf"), Idf);
        IdfParser.Parse(t.File("roll.idf"), out var roll, out var frames);
        roll.AdjustMethod = ToneMethod.Clahe;
        roll.AdjustStrength = 70;
        roll.ArchiveList = "Box 1;Folder A\nBox 1;Folder \\B";
        frames[0].IsMarker = true;
        frames[1].IsSuggested = true;
        frames[1].Rotation = 90;
        frames[1].HasOverride = true;
        frames[1].CustomGamma = 120;
        var project = new Project
        {
            Roll = roll, Frames = frames,
            Notes = "# Roll notes\n\nCheck frame 12 ]]> again & <soon>.",
        };

        string slf = t.File("roll.slf");
        ProjectFile.SaveSlf(slf, t.File("roll.idf"), project);
        Assert.True(ProjectFile.TryLoadProject(slf, out var loaded));

        Assert.Equal(ToneMethod.Clahe, loaded.Roll.AdjustMethod);
        Assert.Equal(70, loaded.Roll.AdjustStrength);
        Assert.Equal(project.Roll.ArchiveList.Replace("\n", Environment.NewLine), loaded.Roll.ArchiveList);
        Assert.Equal(project.Notes, loaded.Notes);
        Assert.Equal(t.File("roll.idf"), loaded.SourceIdfPath);
        Assert.Equal(2, loaded.Frames.Count);
        Assert.True(loaded.Frames[0].IsMarker);
        Assert.True(loaded.Frames[1].IsSuggested);
        Assert.Equal(90, loaded.Frames[1].Rotation);
        Assert.Equal(120, loaded.Frames[1].CustomGamma);
        Assert.Equal(3, loaded.Roll.StripCount);
    }

    [Fact]
    public void QpfOmitsStriplightOnlyData()
    {
        using var t = new TempDir();
        File.WriteAllText(t.File("roll.idf"), Idf);
        IdfParser.Parse(t.File("roll.idf"), out var roll, out var frames);
        frames[0].IsSuggested = true;
        string qpf = t.File("roll.qpf");
        ProjectFile.SaveQpf(qpf, t.File("roll.idf"), new Project { Roll = roll, Frames = frames, Notes = "secret" });
        string text = File.ReadAllText(qpf);
        Assert.DoesNotContain("StriplightSettings", text);
        Assert.DoesNotContain("StriplightNotes", text);
        Assert.DoesNotContain("IsSuggested", text);
        Assert.True(ProjectFile.TryLoadFrames(qpf, out var loaded));
        Assert.Equal(2, loaded.Count);
    }
}

public class NamingAndEditingTests
{
    private static List<FrameRecord> Frames(params bool[] markers) =>
        markers.Select((m, i) => new FrameRecord { Index = i, LeadEdge = i * 100, TrailEdge = i * 100 + 90, LeftEdge = 0, RightEdge = 50, IsMarker = m }).ToList();

    [Fact]
    public void QuantumFolders()
    {
        var f = Frames(true, false, true, false);
        var o = new NamingOptions { OutputRoot = "out", Prefix = "img", FileDigits = 4 };
        Assert.Equal(Path.Combine("out", "0001", "img0002.jpg"), ExportNaming.PathForFrame(f, 1, o).FullPath);
        Assert.Equal(Path.Combine("out", "0002", "img0002.jpg"), ExportNaming.PathForFrame(f, 3, o).FullPath);
        Assert.Equal(Path.Combine("out", "img0001.jpg"), ExportNaming.PathForFrame(f, 2, o with { SeparateFolders = false }).FullPath);
    }

    [Fact]
    public void ArchiveListNaming()
    {
        var f = Frames(true, false, true);
        var o = new NamingOptions { OutputRoot = "out", Mode = 1, FileDigits = 3, ArchiveList = "\n;Box 1; Folder A \n\nBox 2;B\n" };
        Assert.Equal(Path.Combine("out", "Box 1", "Folder A", "Box 1_Folder A_002.jpg"), ExportNaming.PathForFrame(f, 1, o).FullPath);
        Assert.Equal(Path.Combine("out", "Box 2", "B", "Box 2_B_001.jpg"), ExportNaming.PathForFrame(f, 2, o).FullPath);
        Assert.Throws<InvalidOperationException>(() => ExportNaming.PathForFrame(f, 2, o with { ArchiveList = "only one" }));
    }

    [Fact]
    public void ToggleMarkerAndDelete()
    {
        var f = Frames(false, false, false);
        FrameEditor.ToggleMarker(f, [0, 1]);
        Assert.True(f[0].IsMarker && f[1].IsMarker);
        FrameEditor.ToggleMarker(f, [0, 1]);
        Assert.False(f[0].IsMarker || f[1].IsMarker);
        FrameEditor.Delete(f, [1]);
        Assert.Equal(2, f.Count);
        Assert.Equal(1, f[1].Index);
    }

    [Fact]
    public void StatsFlagAbnormalFrames()
    {
        var f = Frames(false, false, false, false);
        f[3].TrailEdge = f[3].LeadEdge + 400; // much taller
        FrameEditor.Refresh(f);
        Assert.True(f[3].IsOversized);
        Assert.False(f[0].IsOversized);
    }
}

public class DetectionTests
{
    [Fact]
    public void FindsBrightBandsInPreview()
    {
        var roll = new RollData { Loaded = true, StripCount = 1, LengthLines = 800, WidthPixels = 400, PreviewDownScale = 4 };
        int w = 100, h = 200; // preview = full / 4
        var px = new byte[w * h];
        for (int y = 20; y < 80; y++) for (int x = 10; x < 90; x++) px[y * w + x] = 220;
        for (int y = 120; y < 180; y++) for (int x = 10; x < 90; x++) px[y * w + x] = 220;
        var img = new DecodedImage(w, h, 1, px);

        var frames = FrameDetector.Detect(roll, new DetectOptions { StripFrom = 0, StripTo = 0, MinWidthPx = 100, MinHeightPx = 100, Threshold = 100 },
            _ => img);
        Assert.Equal(2, frames.Count);
        Assert.Equal(80, frames[0].LeadEdge);
        Assert.Equal(320, frames[0].TrailEdge);
        Assert.Equal(40, frames[0].LeftEdge);
        Assert.Equal(360, frames[0].RightEdge);
    }
}

/// <summary>End-to-end through libturbojpeg (skipped when the native library is missing).</summary>
public class TurboJpegPipelineTests
{
    private static bool Ready => TurboJpeg.IsAvailable;

    [Fact]
    public void EncodeDecodeRoundTrip()
    {
        if (!Ready) return;
        var img = new GrayImage(64, 32);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = (byte)(i % 64 * 4);
        var jpeg = TurboJpeg.EncodeGray(img, 95, false);
        var (w, h, gray) = TurboJpeg.ReadHeader(jpeg);
        Assert.Equal((64, 32, true), (w, h, gray));
        var d = TurboJpeg.Decode(jpeg, TurboJpeg.PixelFormatGray)!;
        Assert.InRange(Math.Abs(d.Pixels[100] - img.Data[100]), 0, 6);
    }

    [Fact]
    public async Task ExportsFrameSpanningTwoStrips()
    {
        if (!Ready) return;
        using var t = new TempDir();
        var roll = new RollData
        {
            Loaded = true, StripCount = 2, LengthLines = 256, WidthPixels = 128, PreviewDownScale = 8,
            BasePath = RollPaths.WithTrailingSeparator(t.Path), StripDigits = 9,
        };
        Directory.CreateDirectory(Path.Combine(t.Path, roll.StripFolder));
        // Strips are stored on their side: image width = across the film, height = along it.
        for (int s = 0; s < 2; s++)
        {
            var strip = new GrayImage(roll.WidthPixels, roll.LengthLines);
            Array.Fill(strip.Data, (byte)(s == 0 ? 60 : 200));
            File.WriteAllBytes(RollPaths.StripFilePath(roll, s), TurboJpeg.EncodeGray(strip, 95, false));
        }
        var frames = new List<FrameRecord>
        {
            new() { Index = 0, LeadEdge = 200, TrailEdge = 300, LeftEdge = 10, RightEdge = 110 },
        };

        var cache = new GrayStripCache(4);
        var built = new FrameBuilder(roll, new ProcessSettings(), cache).Build(frames[0]);
        Assert.Equal((100, 100), (built.Width, built.Height)); // 56 lines + 44 lines wide, 100 across
        Assert.InRange((int)built.Data[10], 50, 70);    // left part comes from strip 0
        Assert.InRange((int)built.Data[90], 190, 210);  // right part from strip 1

        var naming = new NamingOptions { OutputRoot = Path.Combine(t.Path, "frames"), Prefix = "f", FileDigits = 3 };
        var jobs = ExportEngine.BuildJobs(frames, [0], naming);
        var summary = await new ExportEngine().RunAsync(roll, frames, jobs, new ProcessSettings
        {
            Rotation = 90, Tone = new ToneSettings(ToneMethod.AutoLevels, 0, 0, 0, 100, 50),
        }, new ExportOptions { Workers = 2 });

        Assert.Equal(1, summary.Exported);
        Assert.Empty(summary.Failures);
        Assert.True(File.Exists(jobs[0].FullPath));

        var again = await new ExportEngine().RunAsync(roll, frames, jobs, new ProcessSettings(), new ExportOptions { SkipExisting = true });
        Assert.Equal(1, again.Skipped);
    }
}

public class DemoRollTests
{
    [Fact]
    public void DemoRollOpensAndExports()
    {
        if (!TurboJpeg.IsAvailable) return;
        using var t = new TempDir();
        string idf = Striplight.Core.Demo.DemoRoll.Create(t.Path);
        Assert.Equal(IdfParseResult.Ok, IdfParser.Parse(idf, out var roll, out var frames));
        Assert.Equal(Striplight.Core.Demo.DemoRoll.StripCount, roll.StripCount);
        Assert.True(frames.Count > 20);
        Assert.Contains(frames, f => f.SpansStrips(roll.LengthLines));

        // Detection on the previews finds roughly the same pages.
        var found = FrameDetector.Detect(roll, new DetectOptions { StripFrom = 0, StripTo = roll.StripCount - 1, Threshold = 60, MergeAcrossGaps = roll.LengthLines / 64 },
            i => TurboJpeg.DecodeFile(RollPaths.PreviewFilePath(roll, i), TurboJpeg.PixelFormatBgra));
        Assert.InRange(found.Count, frames.Count - 3, frames.Count + 3);

        var img = new FrameBuilder(roll, new ProcessSettings(), new GrayStripCache(4)).Build(frames[3]);
        Assert.Equal(frames[3].Height, img.Width);
    }
}

public class FrameToolTests
{
    private static List<FrameRecord> Row(int n) =>
        Enumerable.Range(0, n).Select(i => new FrameRecord { Index = i, LeadEdge = i * 100, TrailEdge = i * 100 + 90, LeftEdge = 10 + i, RightEdge = 50 }).ToList();

    [Fact]
    public void MergePairsJoinsFirstWithSecond()
    {
        var f = Row(5);
        var keep = FrameEditor.MergePairs(f, [0, 1, 3, 4]);
        Assert.Equal(3, f.Count);
        Assert.Equal((0L, 190L, 10), (f[0].LeadEdge, f[0].TrailEdge, f[0].LeftEdge));
        Assert.Equal(2, keep.Count);
    }

    [Fact]
    public void CombineOnlyMergesOverlapping()
    {
        var f = Row(3);
        f[1].LeadEdge = 50; // overlaps frame 0
        var keep = FrameEditor.CombineOverlapping(f, [0, 1, 2]);
        Assert.Equal(2, f.Count);
        Assert.Equal(190, f[0].TrailEdge);
        Assert.Equal(2, keep.Count);
    }

    [Fact]
    public void SplitMakesEqualParts()
    {
        var f = Row(2);
        f[0].IsMarker = true;
        var parts = FrameEditor.Split(f, [0], 3);
        Assert.Equal(4, f.Count);
        Assert.Equal(new long[] { 0, 30, 60 }, f.Take(3).Select(x => x.LeadEdge));
        Assert.Equal(90, f[2].TrailEdge);
        Assert.True(f[0].IsMarker);
        Assert.False(f[1].IsMarker);
        Assert.Equal(3, parts.Count);
    }

    [Fact]
    public void FindMarkerWraps()
    {
        var f = Row(5);
        f[1].IsMarker = true;
        Assert.Equal(1, FrameEditor.FindMarker(f, 3, forward: true));
        Assert.Equal(1, FrameEditor.FindMarker(f, 0, forward: false));
        Assert.Equal(-1, FrameEditor.FindMarker(Row(2), 0, true));
    }
}

public class ArchiveNamingRealDataTests
{
    // Rows in the format Tom prepares for the archive method (one row per folder marker).
    private const string Rows = ";73;524;0;0;79\n;73;524;0;0;80\n;73;524;0;0;81\n";

    [Fact]
    public void BuildsArchiveFoldersAndFileNames()
    {
        // 3 markers, 2 frames each
        var frames = Enumerable.Range(0, 6).Select(i => new FrameRecord
        {
            Index = i, LeadEdge = i * 100, TrailEdge = i * 100 + 90, LeftEdge = 0, RightEdge = 50, IsMarker = i % 2 == 0,
        }).ToList();
        var o = new NamingOptions { OutputRoot = "OUT", Mode = 1, FileDigits = 5, ArchiveList = Rows };

        string P(params string[] parts) => Path.Combine(parts);
        Assert.Equal(P("OUT", "73", "524", "0", "0", "79", "73_524_0_0_79_00001.jpg"), ExportNaming.PathForFrame(frames, 0, o).FullPath);
        Assert.Equal(P("OUT", "73", "524", "0", "0", "79", "73_524_0_0_79_00002.jpg"), ExportNaming.PathForFrame(frames, 1, o).FullPath);
        Assert.Equal(P("OUT", "73", "524", "0", "0", "80", "73_524_0_0_80_00001.jpg"), ExportNaming.PathForFrame(frames, 2, o).FullPath);
        Assert.Equal(P("OUT", "73", "524", "0", "0", "81", "73_524_0_0_81_00002.jpg"), ExportNaming.PathForFrame(frames, 5, o).FullPath);

        // Marker method on the same frames: 00001\, 00002\, 00003\ with prefix + counter.
        var q = new NamingOptions { OutputRoot = "OUT", Mode = 0, FileDigits = 5, Prefix = "gray" };
        Assert.Equal(P("OUT", "00003", "gray00002.jpg"), ExportNaming.PathForFrame(frames, 5, q).FullPath);
    }
}

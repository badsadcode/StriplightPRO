using System.Text;
using Striplight.Core.Export;
using Striplight.Core.Model;

namespace Striplight.Core.Tests;

public class ProjectReportTests
{
    // Markers start folders; frames per folder as given.
    private static List<FrameRecord> Frames(params int[] perFolder)
    {
        var list = new List<FrameRecord>();
        long at = 0;
        foreach (int n in perFolder)
            for (int k = 0; k < n; k++, at += 1200)
                list.Add(new FrameRecord { LeadEdge = at, TrailEdge = at + 1000, LeftEdge = 0, RightEdge = 900, IsMarker = k == 0, Index = list.Count });
        return list;
    }

    private static NamingOptions Naming(params string[] rows) => new()
    {
        Mode = 1, FileDigits = 5, OutputRoot = @"D:\2026\04112026\18027-18032", ArchiveList = string.Join("\n", rows),
    };

    [Fact]
    public void OneRowPerSeriesWithRangesAndMicrofilm()
    {
        var frames = Frames(2, 3, 1, 2, 1);
        var naming = Naming(";1;62;0;1;11", ";1;62;0;1;14", ";1;62;0;1;05_1R", ";1;63;0;1;2", ";1;62;0;1;12");
        var report = ProjectReportBuilder.Build(frames, naming, ProjectReportBuilder.FormatMicrofilm("18027-18032_18040 18045-18050"),
            _ => 1_250_000_000L);   // every file present, 1.25 GB each

        Assert.Equal(2, report.Rows.Count);
        var r = report.Rows[0];
        Assert.Equal(@"1\62\0\1", r.Identifier);
        Assert.Equal("05_1R; 11-12; 14", r.SignatureList);         // natural order, 11 and 12 joined
        Assert.Equal("18027-18032; 18040; 18045-18050", r.Microfilm);
        Assert.Equal(4, r.Units);
        Assert.Equal(7, r.Files);
        Assert.Equal("8,75", r.Gb);                                // 7 × 1.25 GB, decimal comma
        Assert.Equal(Path.Combine(naming.OutputRoot, "1", "62", "0", "1"), r.Directory);
        Assert.Equal(@"1\63\0\1", report.Rows[1].Identifier);
        Assert.Equal((5, 9, 0), (report.Units, report.Files, report.MissingFiles));
    }

    [Fact]
    public void OnlyFilesOnDiskCountAndMissingOnesAreReported()
    {
        var frames = Frames(3);
        var naming = Naming(";1;63;0;7;5");
        var report = ProjectReportBuilder.Build(frames, naming, "123-213",
            p => p.EndsWith("00002.jpg") ? null : 1000);
        Assert.Equal((2, 1, 3), (report.Files, report.MissingFiles, report.ExpectedFiles));
        Assert.Equal(1, report.Rows[0].MissingFiles);
    }

    [Fact]
    public void MissingArchiveRowsAreCountedNotGuessed()
    {
        var report = ProjectReportBuilder.Build(Frames(1, 2), Naming(";1;63;0;7;5"), "", _ => 10);
        Assert.Equal(2, report.FramesWithoutRow);
        Assert.Single(report.Rows);
    }

    [Fact]
    public void QuantumNamingIsRefused() =>
        Assert.Throws<InvalidOperationException>(() =>
            ProjectReportBuilder.Build(Frames(1), new NamingOptions { Mode = 0, OutputRoot = "D:\\x" }, "", _ => 1));

    [Fact]
    public void ClipboardKeepsTextAsTextAndCanSkipHeaders()
    {
        var report = ProjectReportBuilder.Build(Frames(1, 1), Naming(";1;63;0;1;007", ";1;63;0;1;008"), "5-6", _ => 2000);
        var data = ProjectReportBuilder.ToClipboard(report, null);
        string line = data.Tsv.TrimEnd('\r', '\n');
        Assert.Equal(@"1\63\0\1" + "\t007-008\t5-6\t2\t2\t0,00\t" + report.Rows[0].Directory, line);
        Assert.DoesNotContain("Identyfikator", data.Tsv);
        string html = Encoding.UTF8.GetString(data.CfHtml);
        Assert.Contains("mso-number-format:'\\@'\">007-008<", html);   // signatures pasted as text

        var withHeaders = ProjectReportBuilder.ToClipboard(report, ["Identyfikator", "Sygnatury", "Numer Mikrofilmu", "Liczba j.a.", "Liczba plików", "GB", "Katalog"]);
        Assert.StartsWith("Identyfikator\tSygnatury\tNumer Mikrofilmu", withHeaders.Tsv);
    }

    [Theory]
    [InlineData("123-213", "123-213")]
    [InlineData("123-321_400_405-500", "123-321; 400; 405-500")]
    [InlineData("18062 cz1 i 2", "18062; cz1; i; 2")]
    public void MicrofilmFolderNameBecomesAList(string folder, string expected) =>
        Assert.Equal(expected, ProjectReportBuilder.FormatMicrofilm(folder));
}

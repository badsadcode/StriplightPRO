using Striplight.Core.Model;

namespace Striplight.Core.Export;

public sealed record NamingOptions
{
    public string OutputRoot { get; init; } = "";
    /// <summary>0 = Quantum folders (volume folders + prefix), 1 = archive list rows.</summary>
    public int Mode { get; init; }
    public string Prefix { get; init; } = "";
    public int FileDigits { get; init; } = 5;
    public bool SeparateFolders { get; init; } = true;
    public string ArchiveList { get; init; } = "";
}

public sealed record ExportPath(string FolderPath, string FileName, string FullPath);

/// <summary>
/// Output folder/file naming for exported frames (port of <c>TMainForm.ExportPathForFrame</c>).
/// Each marker starts a new "volume"; frames are numbered from 1 inside their volume.
/// </summary>
public static class ExportNaming
{
    /// <summary>Default output root: a "frames" folder next to the project.</summary>
    public static string DefaultOutputRoot(string projectOrIdfPath, RollData roll)
    {
        string root = !string.IsNullOrEmpty(projectOrIdfPath)
            ? Path.GetDirectoryName(Path.GetFullPath(projectOrIdfPath)) ?? roll.BasePath
            : roll.BasePath;
        return Path.Combine(root, "frames");
    }

    /// <summary>1-based volume number and file number of a frame.</summary>
    public static (int Volume, int FileNo) VolumeAndFile(IReadOnlyList<FrameRecord> frames, int frameIdx)
    {
        int volume = 0, volumeStart = 0;
        for (int i = 0; i <= frameIdx; i++)
            if (frames[i].IsMarker) { volume++; volumeStart = i; }
        if (volume == 0) volume = 1;
        return (volume, Math.Max(1, frameIdx - volumeStart + 1));
    }

    /// <summary>Non-empty, trimmed rows of the archive list.</summary>
    public static List<string> ArchiveRows(string archiveList) =>
        archiveList.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();

    public static ExportPath PathForFrame(IReadOnlyList<FrameRecord> frames, int frameIdx, NamingOptions o)
    {
        if (frameIdx < 0 || frameIdx >= frames.Count) throw new ArgumentOutOfRangeException(nameof(frameIdx), "Frame index out of range.");
        var (volume, fileNo) = VolumeAndFile(frames, frameIdx);
        string folder, file;

        if (o.Mode == 1)
        {
            var rows = ArchiveRows(o.ArchiveList);
            if (volume > rows.Count)
                throw new InvalidOperationException($"Missing archive list row for volume {volume}.");
            // Leading ';' are ignored; each ';'-separated part is a sub-folder and a name part.
            string line = rows[volume - 1].TrimStart(';');
            var parts = line.Split(';').Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
            folder = parts.Aggregate(o.OutputRoot, Path.Combine);
            string prefix = parts.Count > 0 ? string.Join("_", parts) : "archive";
            file = prefix + "_" + RollPaths.ZeroPad(fileNo, o.FileDigits) + ".jpg";
        }
        else
        {
            folder = o.SeparateFolders ? Path.Combine(o.OutputRoot, RollPaths.ZeroPad(volume, o.FileDigits)) : o.OutputRoot;
            file = o.Prefix + RollPaths.ZeroPad(fileNo, o.FileDigits) + ".jpg";
        }
        return new ExportPath(folder, file, Path.Combine(folder, file));
    }
}

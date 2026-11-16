using System.Security.Cryptography;
using System.Text;
using Striplight.Core.Model;

namespace Striplight.Core.IO;

/// <summary>
/// Local preview cache (port of the Lazarus "Cache previews" / background cache / cache manager):
/// the small preview JPEGs of a roll are copied from the (often network) source folder into a
/// local folder and read from there. Copying happens on first use (strip view, detection) or for
/// the whole roll in the background. Full strips are never cached here (export has its own
/// in-memory strip cache). Cache folders: &lt;root&gt;\&lt;roll name&gt;_&lt;hash of source folder&gt;\previews.
/// </summary>
public static class PreviewCache
{
    public sealed record Progress(string Label, int Current, int Total, int Copied, int Skipped, int Missing);
    public sealed record Result(int Copied, int Skipped, int Missing, int Total, bool Cancelled);

    public static string DefaultRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StriplightPRO", "PreviewCache");

    /// <summary>The source preview folder of a roll (where the scanner wrote them).</summary>
    public static string SourceFolder(RollData roll) => Path.GetDirectoryName(RollPaths.PreviewSourcePath(roll, 0)) ?? "";

    /// <summary>Cache folder of one roll: readable name plus a short hash so equal names never collide.</summary>
    public static string ProjectRoot(string cacheRoot, RollData roll, string idfPath)
    {
        string name = !string.IsNullOrWhiteSpace(idfPath) ? Path.GetFileNameWithoutExtension(idfPath)
            : !string.IsNullOrWhiteSpace(roll.RollName) ? roll.RollName : "roll";
        var clean = new StringBuilder();
        foreach (char c in name) clean.Append(Path.GetInvalidFileNameChars().Contains(c) || c == ' ' ? '_' : c);
        byte[] hash = SHA1.HashData(Encoding.UTF8.GetBytes(SourceFolder(roll).ToUpperInvariant()));
        return Path.Combine(cacheRoot, $"{clean}_{Convert.ToHexString(hash, 0, 4).ToLowerInvariant()}");
    }

    /// <summary>Reads previews through the cache folder (copies each on first use).</summary>
    public static void Enable(RollData roll, string projectRoot)
    {
        Remember(roll);
        roll.PreviewBasePath = RollPaths.WithTrailingSeparator(projectRoot);
        roll.PreviewFolder = "previews";
        roll.PreviewCacheEnabled = true;
    }

    /// <summary>Reads previews from their source folder again.</summary>
    public static void Disable(RollData roll)
    {
        Remember(roll);
        roll.PreviewBasePath = roll.PreviewSourceBasePath;
        roll.PreviewFolder = roll.PreviewSourceFolder;
        roll.PreviewCacheEnabled = false;
    }

    private static void Remember(RollData roll)
    {
        if (string.IsNullOrEmpty(roll.PreviewSourceBasePath)) roll.PreviewSourceBasePath = roll.PreviewBasePath != "" ? roll.PreviewBasePath : roll.BasePath;
        if (string.IsNullOrEmpty(roll.PreviewSourceFolder)) roll.PreviewSourceFolder = roll.PreviewFolder;
    }

    /// <summary>How many of the roll's previews are already in its cache folder.</summary>
    public static (int Cached, int Total) Count(RollData roll, string projectRoot)
    {
        int cached = 0;
        string folder = Path.Combine(projectRoot, "previews");
        if (Directory.Exists(folder))
            for (int i = 0; i < roll.StripCount; i++)
                if (File.Exists(Path.Combine(folder, Path.GetFileName(RollPaths.PreviewSourcePath(roll, i))))) cached++;
        return (cached, roll.StripCount);
    }

    /// <summary>Copies every preview of the roll that is not cached yet (the background cache).</summary>
    public static Result CacheRoll(RollData roll, string projectRoot, string label,
        IProgress<Progress>? progress = null, CancellationToken cancel = default)
    {
        string folder = Path.Combine(projectRoot, "previews");
        Directory.CreateDirectory(folder);
        int copied = 0, skipped = 0, missing = 0, total = roll.StripCount;
        for (int i = 0; i < total; i++)
        {
            if (cancel.IsCancellationRequested) return new Result(copied, skipped, missing, total, true);
            string source = RollPaths.PreviewSourcePath(roll, i);
            string target = Path.Combine(folder, Path.GetFileName(source));
            if (File.Exists(target)) skipped++;
            else if (File.Exists(source))
            {
                try
                {
                    // Copy to a temporary name first: a half-copied preview is never used.
                    string tmp = target + ".part";
                    File.Copy(source, tmp, overwrite: true);
                    File.Move(tmp, target, overwrite: true);
                    copied++;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { missing++; }
            }
            else missing++;
            if (i + 1 == total || (i + 1) % 10 == 0)
                progress?.Report(new Progress(label, i + 1, total, copied, skipped, missing));
        }
        return new Result(copied, skipped, missing, total, false);
    }

    public static long SizeBytes(string folder)
    {
        if (!Directory.Exists(folder)) return 0;
        long total = 0;
        try
        {
            foreach (var f in new DirectoryInfo(folder).EnumerateFiles("*", SearchOption.AllDirectories)) total += f.Length;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return total;
    }

    /// <summary>Deletes a cache folder (only folders inside the cache root are ever deleted).</summary>
    public static bool Clear(string folder, string cacheRoot)
    {
        string full = Path.GetFullPath(folder), root = RollPaths.WithTrailingSeparator(Path.GetFullPath(cacheRoot));
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase) && !string.Equals(RollPaths.WithTrailingSeparator(full), root, StringComparison.OrdinalIgnoreCase))
            return false;
        if (!Directory.Exists(full)) return true;
        try { Directory.Delete(full, recursive: true); return true; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>
    /// Roll data for caching a project that is not open (cache manager queue): an .idf, or an
    /// .slf / .qpf whose source .idf is found. Null if it cannot be read.
    /// </summary>
    public static (RollData Roll, string IdfPath)? LoadRoll(string path)
    {
        try
        {
            string ext = Path.GetExtension(path).ToLowerInvariant();
            string idf = path;
            if (ext != ".idf")
            {
                if (!ProjectFile.TryLoadProject(path, out var p)) return null;
                idf = File.Exists(p.SourceIdfPath) ? p.SourceIdfPath : Path.ChangeExtension(path, ".idf");
            }
            if (!File.Exists(idf) || IdfParser.Parse(idf, out var roll, out _) != IdfParseResult.Ok) return null;
            string dir = RollPaths.WithTrailingSeparator(Path.GetDirectoryName(Path.GetFullPath(idf))!);
            roll.BasePath = roll.PreviewBasePath = roll.PreviewSourceBasePath = dir;
            return (roll, idf);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>Every .idf under a folder (cache manager "Add folder").</summary>
    public static List<string> FindRolls(string folder)
    {
        var found = new List<string>();
        try
        {
            foreach (string f in Directory.EnumerateFiles(folder, "*.idf", new EnumerationOptions
            {
                RecurseSubdirectories = true, IgnoreInaccessible = true, MaxRecursionDepth = 6,
            }))
                found.Add(f);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        found.Sort(StringComparer.OrdinalIgnoreCase);
        return found;
    }
}

namespace Striplight.Core.Model;

/// <summary>Strip and preview file naming (port of the path helpers in uTypes.pas).</summary>
public static class RollPaths
{
    public static string ZeroPad(int value, int digits) =>
        value.ToString(System.Globalization.CultureInfo.InvariantCulture).PadLeft(Math.Max(0, digits), '0');

    /// <summary>Full-resolution strip file. Files on disk are 1-based (strip000000001.jpg ...).</summary>
    public static string StripFilePath(RollData roll, int stripIndex) =>
        Path.Combine(roll.BasePath, roll.StripFolder,
            roll.StripPrefix + ZeroPad(stripIndex + 1, roll.StripDigits) + ".jpg");

    /// <summary>Preview file in the original (source) location.</summary>
    public static string PreviewSourcePath(RollData roll, int stripIndex)
    {
        string baseDir = string.IsNullOrEmpty(roll.PreviewSourceBasePath) ? roll.BasePath : roll.PreviewSourceBasePath;
        string folder = string.IsNullOrEmpty(roll.PreviewSourceFolder) ? roll.PreviewFolder : roll.PreviewSourceFolder;
        return Path.Combine(baseDir, folder,
            roll.PreviewPrefix + ZeroPad(stripIndex + 1, roll.StripDigits) + ".jpg");
    }

    /// <summary>Preview file in the (possibly local) cache location.</summary>
    public static string PreviewCachePath(RollData roll, int stripIndex) =>
        Path.Combine(string.IsNullOrEmpty(roll.PreviewBasePath) ? roll.BasePath : roll.PreviewBasePath,
            roll.PreviewFolder,
            roll.PreviewPrefix + ZeroPad(stripIndex + 1, roll.StripDigits) + ".jpg");

    /// <summary>
    /// Preview file to read. With the preview cache enabled, the source file is copied
    /// into the cache on first use and the cached copy is returned.
    /// </summary>
    public static string PreviewFilePath(RollData roll, int stripIndex)
    {
        string cachePath = PreviewCachePath(roll, stripIndex);
        if (roll.PreviewCacheEnabled && File.Exists(cachePath)) return cachePath;

        string source = PreviewSourcePath(roll, stripIndex);
        if (roll.PreviewCacheEnabled && File.Exists(source) &&
            !string.Equals(Path.GetFullPath(source), Path.GetFullPath(cachePath), StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(cachePath)!);
                // Copy under a unique name, then rename: a half-copied preview is never read,
                // even when the view and detection ask for the same strip at once.
                string tmp = cachePath + "." + Guid.NewGuid().ToString("N")[..8] + ".part";
                File.Copy(source, tmp, overwrite: true);
                File.Move(tmp, cachePath, overwrite: true);
                if (File.Exists(cachePath)) return cachePath;
            }
            catch (IOException) { /* fall back to the original preview */ }
            catch (UnauthorizedAccessException) { }
        }
        return source;
    }

    /// <summary>Base directory with a trailing separator, as the Pascal code expects.</summary>
    public static string WithTrailingSeparator(string dir) =>
        string.IsNullOrEmpty(dir) || Path.EndsInDirectorySeparator(dir) ? dir : dir + Path.DirectorySeparatorChar;
}

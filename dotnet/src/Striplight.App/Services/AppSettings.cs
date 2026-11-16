using System.IO;
using System.Text.Json;
using Striplight.App.Bridge;

namespace Striplight.App.Services;

/// <summary>Per-user preferences (not per roll), stored in %APPDATA%\StriplightPRO\settings.json.</summary>
public sealed class AppSettings
{
    public string LastFolder { get; set; } = "";
    public List<string> RecentProjects { get; set; } = [];

    // View
    public int StripsPerRow { get; set; } = 4;
    public double Zoom { get; set; } = 1.0;
    public bool RotateCw { get; set; }
    public int FrameFillOpacity { get; set; } = 35;
    /// <summary>Fit as many strips per row as the window allows.</summary>
    public bool AutoStrips { get; set; }
    public bool ShowStripNumbers { get; set; }
    public bool MultiEdit { get; set; }
    /// <summary>UI language: "en" (default) or "pl".</summary>
    public string Language { get; set; } = "en";
    /// <summary>Size check (Lazarus "Detect Oversized / Undersized Frames").</summary>
    /// <summary>Preview cache (Lazarus "Cache previews"): read previews through a local copy.</summary>
    public bool CachePreviews { get; set; }
    /// <summary>Cache root; empty = %LOCALAPPDATA%\StriplightPRO\PreviewCache.</summary>
    public string CacheFolder { get; set; } = "";
    /// <summary>Cache manager queue: .idf / .slf paths to cache in the background.</summary>
    public List<string> CacheQueue { get; set; } = [];
    public bool SizeOverOn { get; set; } = true;
    public int SizeOverPercent { get; set; } = 50;
    public bool SizeUnderOn { get; set; } = true;
    public int SizeUnderPercent { get; set; } = 50;
    /// <summary>Custom shortcuts: command id -> keys (e.g. "Ctrl+S"). Empty = built-in defaults.</summary>
    public Dictionary<string, List<string>> KeyBindings { get; set; } = [];
    /// <summary>"dark" or "light".</summary>
    public string Theme { get; set; } = "dark";

    // Preview window
    public bool PreviewTopmost { get; set; }
    public int PreviewStep { get; set; } = 1;
    public bool PreviewFullQuality { get; set; }
    public double? PreviewLeft { get; set; }
    public double? PreviewTop { get; set; }
    public double PreviewWidth { get; set; } = 960;
    public double PreviewHeight { get; set; } = 760;

    // Export defaults
    public string Prefix { get; set; } = "gray"; // Lazarus default
    public int FileDigits { get; set; } = 5;
    public bool SeparateFolders { get; set; } = true;
    public int Quality { get; set; } = 100;
    public bool SkipExisting { get; set; }
    public bool AllowPreviewFallback { get; set; }
    public bool LocalTempStage { get; set; }
    public int Workers { get; set; } = Math.Clamp(Environment.ProcessorCount / 2, 1, 16);
    public int StripCacheLimit { get; set; } = 8;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StriplightPRO", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), BridgeHost.Json) ?? new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return new();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions(BridgeHost.Json) { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void AddRecent(string path)
    {
        RecentProjects.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        RecentProjects.Insert(0, path);
        if (RecentProjects.Count > 10) RecentProjects.RemoveRange(10, RecentProjects.Count - 10);
    }
}

/// <summary>Opening things outside the app.</summary>
public static class Shell
{
    public static void OpenUrl(string url)
    {
        if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return;
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
    }

    public static void OpenFolder(string path)
    {
        if (!Directory.Exists(path)) throw new BridgeException(Loc.T("Folder does not exist yet: {path}", ("path", path)));
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }
}

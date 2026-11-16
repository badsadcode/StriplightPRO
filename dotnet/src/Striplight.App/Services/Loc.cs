using System.IO;
using System.Text.Json;

namespace Striplight.App.Services;

/// <summary>
/// Translations. The English text is the key: <c>wwwroot/i18n/{lang}.json</c> maps it to the
/// translation, and a file with the same name in <c>%APPDATA%\StriplightPRO\lang</c> overrides
/// single entries (the user's own fixes survive updates). Anything missing stays English.
/// A value is either a string or, for counts, an object of plural forms
/// (<c>one</c>, <c>few</c>, <c>many</c>, <c>other</c>) chosen by the page with Intl.PluralRules.
/// The page (wwwroot/js/i18n.js) and the host share the same dictionary.
/// </summary>
public static class Loc
{
    public static readonly string[] Languages = ["en", "pl"];

    public static string Language { get; private set; } = "en";

    /// <summary>The merged dictionary as JSON values (strings or plural objects), sent to the page.</summary>
    public static Dictionary<string, JsonElement> Dictionary { get; private set; } = [];

    public static string BuiltInFolder => Path.Combine(AppContext.BaseDirectory, "wwwroot", "i18n");

    public static string UserFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StriplightPRO", "lang");

    public static void Load(string? language)
    {
        Language = Languages.Contains(language) ? language! : "en";
        var dict = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        if (Language != "en")
        {
            Merge(dict, Path.Combine(BuiltInFolder, Language + ".json"));
            Merge(dict, Path.Combine(UserFolder, Language + ".json"));
        }
        Dictionary = dict;
    }

    private static void Merge(Dictionary<string, JsonElement> dict, string path)
    {
        try
        {
            if (!File.Exists(path)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(path),
                new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            foreach (var p in doc.RootElement.EnumerateObject())
            {
                // Empty strings mean "not translated yet": keep the earlier value / English.
                if (p.Value.ValueKind == JsonValueKind.String && p.Value.GetString() == "") continue;
                if (p.Value.ValueKind is JsonValueKind.String or JsonValueKind.Object) dict[p.Name] = p.Value.Clone();
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }

    /// <summary>Translates <paramref name="english"/> and fills {name} placeholders.</summary>
    public static string T(string english, params (string Name, object? Value)[] vars)
    {
        string s = english;
        if (Dictionary.TryGetValue(english, out var v))
        {
            if (v.ValueKind == JsonValueKind.String) s = v.GetString() ?? english;
            else if (v.ValueKind == JsonValueKind.Object && v.TryGetProperty("other", out var o) && o.ValueKind == JsonValueKind.String)
                s = o.GetString() ?? english;
        }
        foreach (var (name, value) in vars) s = s.Replace("{" + name + "}", value?.ToString() ?? "");
        return s;
    }

    /// <summary>
    /// Copies the built-in file for the current language to the user folder (if not there yet)
    /// so it can be edited, and returns the folder.
    /// </summary>
    public static string PrepareUserFolder()
    {
        Directory.CreateDirectory(UserFolder);
        foreach (string lang in Languages.Where(l => l != "en"))
        {
            string src = Path.Combine(BuiltInFolder, lang + ".json"), dst = Path.Combine(UserFolder, lang + ".json");
            if (File.Exists(src) && !File.Exists(dst)) File.Copy(src, dst);
        }
        return UserFolder;
    }
}

using System.Globalization;
using System.Xml.Linq;

namespace Striplight.Core.IO;

/// <summary>Lenient attribute readers matching the Pascal StrToIntDef behaviour.</summary>
internal static class XmlAttr
{
    public static string Str(XElement? e, string name, string def = "") =>
        (string?)e?.Attribute(name) ?? def;

    public static int Int(XElement? e, string name, int def = 0) =>
        int.TryParse(Str(e, name), NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : def;

    public static long Int64(XElement? e, string name, long def = 0) =>
        long.TryParse(Str(e, name), NumberStyles.Integer, CultureInfo.InvariantCulture, out long v) ? v : def;

    public static bool Bool(XElement? e, string name, bool def = false) =>
        Str(e, name).ToLowerInvariant() switch
        {
            "true" or "1" or "yes" => true,
            "false" or "0" or "no" => false,
            _ => def,
        };

    public static XElement? Child(XElement? e, string name) => e?.Element(name);
}

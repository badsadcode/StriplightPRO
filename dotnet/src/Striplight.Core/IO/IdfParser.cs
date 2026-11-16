using System.Xml;
using System.Xml.Linq;
using Striplight.Core.Model;

namespace Striplight.Core.IO;

public enum IdfParseResult { Ok, FileNotFound, InvalidXml, MissingRoot, MissingScanner }

/// <summary>
/// Parses the IDF (XML) files produced by QuantumScan (port of lazarus/uIDFParser.pas).
/// <code>
/// &lt;Roll RollName=".." RollNumber=".." RollID=".."&gt;
///   &lt;ScannerSettings StripCount=".." WidthPixels=".." LengthLines=".." ...&gt;
///     &lt;DetectionSettings&gt;&lt;Frame LeadEdge=".." TrailEdge=".." LeftEdge=".." RightEdge=".."/&gt;...
/// </code>
/// </summary>
public static class IdfParser
{
    public static IdfParseResult Parse(string fileName, out RollData roll, out List<FrameRecord> frames)
    {
        roll = new RollData();
        frames = [];
        if (!File.Exists(fileName)) return IdfParseResult.FileNotFound;

        XDocument doc;
        try { doc = XDocument.Load(fileName); }
        catch (XmlException) { return IdfParseResult.InvalidXml; }

        var rollNode = doc.Root;
        if (rollNode is null || rollNode.Name.LocalName != "Roll") return IdfParseResult.MissingRoot;

        roll.RollName = XmlAttr.Str(rollNode, "RollName");
        roll.RollNumber = XmlAttr.Str(rollNode, "RollNumber");
        roll.RollId = XmlAttr.Str(rollNode, "RollID");
        roll.BasePath = RollPaths.WithTrailingSeparator(Path.GetDirectoryName(Path.GetFullPath(fileName)) ?? "");
        roll.PreviewBasePath = roll.BasePath;
        if (roll.RollName.Length == 0 || roll.RollName.Equals("none", StringComparison.OrdinalIgnoreCase))
            roll.RollName = Path.GetFileNameWithoutExtension(fileName);

        var scanner = rollNode.Element("ScannerSettings");
        if (scanner is null) return IdfParseResult.MissingScanner;

        ReadScannerSettings(scanner, roll);
        roll.PreviewSourceBasePath = roll.BasePath;
        roll.PreviewSourceFolder = roll.PreviewFolder;
        roll.Normalise();

        var detection = scanner.Element("DetectionSettings");
        if (detection is null)
        {
            roll.Loaded = true;
            return IdfParseResult.Ok; // roll not detected yet
        }

        roll.DetectionThreshold = XmlAttr.Int(detection, "DetectionThreshold", 100);
        roll.DetectMinWidth = XmlAttr.Int(detection, "DetectMinWidth", 252);
        roll.DetectMinLength = XmlAttr.Int(detection, "DetectMinLength", 252);

        // The IDF parser keeps every <Frame>, even degenerate ones, like the original.
        foreach (var f in detection.Elements("Frame"))
        {
            frames.Add(new FrameRecord
            {
                Index = frames.Count,
                LeadEdge = XmlAttr.Int64(f, "LeadEdge"),
                TrailEdge = XmlAttr.Int64(f, "TrailEdge"),
                LeftEdge = XmlAttr.Int(f, "LeftEdge"),
                RightEdge = XmlAttr.Int(f, "RightEdge"),
            });
        }
        roll.Loaded = true;
        return IdfParseResult.Ok;
    }

    /// <summary>Shared by the IDF and the QPF/SLF loaders.</summary>
    internal static void ReadScannerSettings(XElement scanner, RollData roll)
    {
        roll.StripCount = XmlAttr.Int(scanner, "StripCount", 0);
        roll.Dpi = XmlAttr.Int(scanner, "DPI", 300);
        roll.WidthPixels = XmlAttr.Int(scanner, "WidthPixels", 4916);
        roll.LengthLines = XmlAttr.Int(scanner, "LengthLines", 4096);
        roll.PreviewDownScale = XmlAttr.Int(scanner, "StripPreviewDownScale", RollData.DefaultPreviewDownScale);
        roll.StripFolder = XmlAttr.Str(scanner, "StripImageFolder", "strips");
        roll.PreviewFolder = XmlAttr.Str(scanner, "StripPreviewImageFolder", "previews");
        roll.StripPrefix = XmlAttr.Str(scanner, "StripImageFilePrefix", "strip");
        roll.PreviewPrefix = XmlAttr.Str(scanner, "StripPreviewImageFilePrefix", "preview");
        roll.StripDigits = XmlAttr.Int(scanner, "StripImageFileDigits", RollData.DefaultStripDigits);
        roll.StripPixels = XmlAttr.Int(scanner, "StripPixels", roll.WidthPixels);
        roll.JpgQuality = XmlAttr.Int(scanner, "JpgQuality", RollData.DefaultJpgQuality);
        roll.SoftwareContrast = XmlAttr.Int(scanner, "SoftwareContrast", 0);
        roll.SoftwareBrightness = XmlAttr.Int(scanner, "SoftwareBrightness", 0);
        roll.SoftwareGamma = XmlAttr.Int(scanner, "SoftwareGamma", 0);
    }

    public static string Message(IdfParseResult r) => r switch
    {
        IdfParseResult.Ok => "OK",
        IdfParseResult.FileNotFound => "IDF file not found.",
        IdfParseResult.InvalidXml => "File is not valid XML.",
        IdfParseResult.MissingRoot => "Expected <Roll> as root element.",
        IdfParseResult.MissingScanner => "<ScannerSettings> element not found.",
        _ => "Unknown error.",
    };
}

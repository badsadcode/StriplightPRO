using System.Globalization;
using System.Security;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Striplight.Core.Model;

namespace Striplight.Core.IO;

/// <summary>A loaded project: roll metadata, frames and the roll notes (Markdown).</summary>
public sealed class Project
{
    public RollData Roll { get; set; } = new();
    public List<FrameRecord> Frames { get; set; } = [];
    /// <summary>Markdown notes edited in the TOAST UI panel. Only stored in SLF files.</summary>
    public string Notes { get; set; } = "";
    /// <summary>IDF the project was created from (SLF <c>SourceIDFPath</c>).</summary>
    public string SourceIdfPath { get; set; } = "";
}

/// <summary>
/// QPF (QuantumScan project) and SLF (Striplight project) files — port of lazarus/uQPF.pas.
/// Both are the QuantumScan roll XML; SLF adds &lt;StriplightSettings&gt;, Striplight-only frame
/// attributes and, new in this edition, &lt;StriplightNotes&gt;. The Lazarus edition ignores
/// elements it does not know, so SLF files stay readable by both editions.
/// </summary>
public static class ProjectFile
{
    public static string QpfPathForIdf(string idfPath) => Path.ChangeExtension(idfPath, ".qpf");
    public static string SlfPathForIdf(string idfPath) => Path.ChangeExtension(idfPath, ".slf");

    // ------------------------------------------------------------------ save

    public static void SaveQpf(string fileName, string idfPath, Project project) =>
        SaveRollXml(fileName, idfPath, project, includeStriplightFields: false);

    public static void SaveSlf(string fileName, string idfPath, Project project) =>
        SaveRollXml(fileName, idfPath, project, includeStriplightFields: true);

    private static void SaveRollXml(string fileName, string idfPath, Project project, bool includeStriplightFields)
    {
        string? dir = Path.GetDirectoryName(Path.GetFullPath(fileName));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        // Written line by line (not via XDocument) so the output matches the files the
        // Lazarus edition and QuantumScan produce, attribute order included.
        var sb = new StringBuilder();
        WriteRollHeader(sb, idfPath, project, includeStriplightFields);
        WriteScannerSettings(sb, project.Roll, "1", includeFrames: false, project.Frames, includeStriplightFields);
        WriteScannerSettings(sb, project.Roll, "QP", includeFrames: true, project.Frames, includeStriplightFields);
        sb.Append("</Roll>").Append(NL);

        // Write to a temp file first so a failed save never truncates the existing project.
        string temp = fileName + ".tmp";
        File.WriteAllText(temp, sb.ToString(), new UTF8Encoding(false));
        File.Move(temp, fileName, overwrite: true);
    }

    private const string NL = "\r\n";

    private static string X(string s) => SecurityElement.Escape(s) ?? "";
    private static string I(long v) => v.ToString(CultureInfo.InvariantCulture);
    private static string B(bool v) => v ? "True" : "False";

    internal static string EncodeSlfText(string s) =>
        s.Replace("\\", "\\\\").Replace("\r\n", "\\n").Replace("\n", "\\n").Replace("\r", "\\n");

    internal static string DecodeSlfText(string s)
    {
        // Accept normal escapes and values passed through one extra escaping layer.
        string nl = Environment.NewLine;
        return s.Replace("\\\\r\\\\n", nl).Replace("\\\\n", nl)
                .Replace("\\r\\n", nl).Replace("\\n", nl).Replace("\\r", nl)
                .Replace("\\\\", "\\");
    }

    private static void WriteRollHeader(StringBuilder sb, string idfPath, Project p, bool isSlf)
    {
        var r = p.Roll;
        string generatedBy = isSlf ? "Striplight SLF" : "QuantumScan 1.02.26";
        sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>").Append(NL);
        sb.Append($"<Roll RollName=\"{X(r.RollName)}\" RollNumber=\"{X(r.RollNumber)}\" JobName=\"{X(r.RollName)}\" RollID=\"{X(r.RollId)}\" GeneratedBy=\"{generatedBy}\" ScanUserID=\"unknown\" ProcessUserID=\"unknown\">").Append(NL);
        if (!isSlf) return;

        sb.Append("  <StriplightSettings Format=\"SLF\" Version=\"2\"")
          .Append($" SourceIDFPath=\"{X(idfPath)}\" SourceIDFFile=\"{X(Path.GetFileName(idfPath))}\"")
          .Append($" SavedAt=\"{X(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture))}\"")
          .Append($" AdjustMethod=\"{I(r.AdjustMethod)}\" AdjustFlags=\"{I(r.AdjustFlags)}\"")
          .Append($" AdjustContrast=\"{I(r.AdjustContrast)}\" AdjustBrightness=\"{I(r.AdjustBrightness)}\"")
          .Append($" AdjustGamma=\"{I(r.AdjustGamma)}\" AdjustStrength=\"{I(r.AdjustStrength)}\"")
          .Append($" Sharpness=\"{I(r.Sharpness)}\" SharpnessMode=\"{I(r.SharpnessMode)}\"")
          .Append($" ExportNamingMode=\"{I(r.ExportNamingMode)}\"")
          .Append($" ExportGrayscale=\"{B(r.ExportGrayscale)}\" ExportProgressive=\"{B(r.ExportProgressive)}\"")
          .Append($" ExportEncoder=\"{I(r.ExportEncoder)}\"")
          .Append($" ArchiveList=\"{X(EncodeSlfText(r.ArchiveList))}\"")
          .Append($" ReportMicrofilm=\"{X(r.ReportMicrofilm)}\" />").Append(NL);

        if (!string.IsNullOrEmpty(r.StriplightState))
        {
            string state = r.StriplightState.Replace("]]>", "]]]]><![CDATA[>");
            sb.Append("  <StriplightState Format=\"json\"><![CDATA[").Append(state).Append("]]></StriplightState>").Append(NL);
        }
        if (!string.IsNullOrEmpty(p.Notes))
        {
            // CDATA keeps Markdown readable in the file; "]]>" has to be split across sections.
            string cdata = p.Notes.Replace("]]>", "]]]]><![CDATA[>");
            sb.Append("  <StriplightNotes Format=\"markdown\"><![CDATA[").Append(cdata).Append("]]></StriplightNotes>").Append(NL);
        }
    }

    private static void WriteScannerSettings(StringBuilder sb, RollData r, string id, bool includeFrames,
        IReadOnlyList<FrameRecord> frames, bool includeStriplightFields)
    {
        string detectionId = includeFrames && !includeStriplightFields ? "" : id;

        if (includeFrames)
            sb.Append($"  <ScannerSettings ID=\"{X(id)}\" StripCount=\"0\" StartStripNumber=\"0\" StartLineNumber=\"0\" NegativeFilm=\"0\" LensPosition=\"0\" DPI=\"0\" ReductionRatio=\"0\" WidthPixels=\"0\" LengthLines=\"0\" StripImageFolder=\"\" StripImageFilePrefix=\"\" StripImageFileDigits=\"0\" StripPreviewImageFolder=\"\" StripPreviewImageFilePrefix=\"\" StripPreviewImageFileDigits=\"0\" StripPreviewDownScale=\"0\" JpgQuality=\"0\" SaveBitonalStrip=\"0\" SaveGrayScaleStrip=\"0\" SoftwareGrayAdjustEnable=\"0\" SoftwareContrast=\"0\" SoftwareBrightness=\"0\" SoftwareGamma=\"0\" StripLimitRegion=\"0\" StripLeftOffset=\"0\" StripPixels=\"0\" IsFicheScan=\"0\">").Append(NL);
        else
            sb.Append($"  <ScannerSettings ID=\"{X(id)}\" StripCount=\"{I(r.StripCount)}\" StartStripNumber=\"1\" StartLineNumber=\"0\" NegativeFilm=\"0\" LensPosition=\"0\" DPI=\"{I(r.Dpi)}\" ReductionRatio=\"0\" WidthPixels=\"{I(r.WidthPixels)}\" LengthLines=\"{I(r.LengthLines)}\" StripImageFolder=\"{X(r.StripFolder)}\" StripImageFilePrefix=\"{X(r.StripPrefix)}\" StripImageFileDigits=\"{I(r.StripDigits)}\" StripPreviewImageFolder=\"{X(r.PreviewSourceFolder)}\" StripPreviewImageFilePrefix=\"{X(r.PreviewPrefix)}\" StripPreviewImageFileDigits=\"{I(r.StripDigits)}\" StripPreviewDownScale=\"{I(r.PreviewDownScale)}\" JpgQuality=\"{I(r.JpgQuality)}\" SaveBitonalStrip=\"0\" SaveGrayScaleStrip=\"1\" SoftwareGrayAdjustEnable=\"1\" SoftwareContrast=\"{I(r.SoftwareContrast)}\" SoftwareBrightness=\"{I(r.SoftwareBrightness)}\" SoftwareGamma=\"{I(r.SoftwareGamma)}\" StripLimitRegion=\"0\" StripLeftOffset=\"0\" StripPixels=\"{I(r.StripPixels)}\" IsFicheScan=\"0\">").Append(NL);

        sb.Append($"    <DetectionSettings ID=\"{X(detectionId)}\" StartStripNumber=\"0\" StartLineNumber=\"0\" AutoFramingMode=\"1\" DetectionThreshold=\"{I(r.DetectionThreshold)}\" DetectMinWidth=\"{I(r.DetectMinWidth)}\" DetectMinLength=\"{I(r.DetectMinLength)}\" DetectOverscanWidth=\"100\" DetectOverscanLines=\"100\" DetectMinRunLength=\"12\" DetectTouchRangeX=\"32\" DetectTouchRangeY=\"3\" DetectMaxFrameLength=\"32768\" DetectLimitRegion=\"0\" DetectLimitLeftOffset=\"0\" DetectLimitPixels=\"{I(r.StripPixels)}\" DetectInvertDetection=\"0\" BlipDetection=\"0\" BlipMinWidth=\"0\" BlipMaxWidth=\"0\" BlipMinLength=\"0\" BlipMaxLength=\"0\" BlipLimitRegion=\"0\" BlipLimitLeftOffset=\"0\" BlipLimitPixels=\"0\" ProcessSettingsExist=\"1\" ProcessSaveGrayscale=\"1\" ProcessGrayscaleFormat=\"0\" ProcessSaveBitonal=\"0\" ProcessBitonalFormat=\"0\" ProcessJpgQuality=\"{I(r.JpgQuality)}\" ProcessSoftwareContrast=\"{I(r.SoftwareContrast)}\" ProcessSoftwareBrightness=\"{I(r.SoftwareBrightness)}\" ProcessSoftwareGamma=\"{I(r.SoftwareGamma)}\" ")
          .Append(QuantumProcessTail)
          .Append(includeFrames ? ">" : " />").Append(NL);

        if (includeFrames)
        {
            foreach (var f in frames)
            {
                if (!f.IsPersistable) continue;
                int flip = (f.FlipH ? 1 : 0) | (f.FlipV ? 2 : 0);
                sb.Append($"      <Frame LeadEdge=\"{I(f.LeadEdge)}\" LeftEdge=\"{I(f.LeftEdge)}\" RightEdge=\"{I(f.RightEdge)}\" TrailEdge=\"{I(f.TrailEdge)}\"");
                if (f.IsMarker) sb.Append(" IsMarker=\"True\"");
                if (f.PerFrameBrightness != -1) sb.Append($" PerFrameBrightness=\"{I(f.PerFrameBrightness)}\"");
                if (f.PerFrameContrast != -1) sb.Append($" PerFrameContrast=\"{I(f.PerFrameContrast)}\"");
                if (f.PerFrameGamma != -1) sb.Append($" PerFrameGamma=\"{I(f.PerFrameGamma)}\"");
                if (f.Rotation != 0) sb.Append($" PerFrameRotate=\"{I(f.Rotation)}\"");
                if (flip != 0) sb.Append($" PerFrameFlip=\"{I(flip)}\"");
                if (includeStriplightFields)
                {
                    if (f.IsSuggested) sb.Append(" IsSuggested=\"True\"");
                    if (f.CustomBrightness != -1) sb.Append($" CustomBrightness=\"{I(f.CustomBrightness)}\"");
                    if (f.CustomContrast != -1) sb.Append($" CustomContrast=\"{I(f.CustomContrast)}\"");
                    if (f.CustomGamma != -1) sb.Append($" CustomGamma=\"{I(f.CustomGamma)}\"");
                    if (f.CustomToneMethod >= 0)
                        sb.Append($" CustomToneMethod=\"{I(f.CustomToneMethod)}\" CustomToneFlags=\"{I(f.CustomToneFlags)}\" CustomStrength=\"{I(f.CustomStrength)}\"");
                    if (f.Rotation != 0) sb.Append($" Rotation=\"{I(f.Rotation)}\"");
                    if (f.FlipH) sb.Append(" FlipH=\"True\"");
                    if (f.FlipV) sb.Append(" FlipV=\"True\"");
                    if (f.Negative) sb.Append(" Negative=\"True\"");
                    if (f.HasOverride) sb.Append(" HasOverride=\"True\"");
                }
                sb.Append(" />").Append(NL);
            }
            sb.Append("    </DetectionSettings>").Append(NL);
        }
        sb.Append("  </ScannerSettings>").Append(NL);
    }

    /// <summary>Fixed QuantumScan process attributes, copied verbatim from the Lazarus writer.</summary>
    private const string QuantumProcessTail =
        "ProcessSoftwareGrayAdjust=\"1\" ProcessBitonalThreshold=\"100\" ProcessBitonalSensitivity=\"12\" ProcessBitonalSlope=\"1\" ProcessRotate=\"0\" ProcessFlip=\"0\" ProcessCrop=\"0\" ProcessDeskew=\"0\" ProcessInvert=\"0\" ProcessCropThreshold=\"128\" ProcessCropDetectPercent=\"20\" ProcessCropDetectColor=\"255\" ProcessCropBorderSize=\"0\" ProcessDeskewFillColor=\"0\" ProcessDeskewTransformQuality=\"0\" ProcessCropFillBorder=\"0\" ProcessCropFillColor=\"0\" ProcessCropFillForward=\"0\" ProcessGrayscaleOutputDirectory=\"\" ProcessGrayscaleFilenamePrefix=\"gray\" ProcessGrayscaleFilenameDigits=\"5\" ProcessBitonalOutputDirectory=\"\" ProcessBitonalFilenamePrefix=\"bitonal\" ProcessBitonalFilenameDigits=\"5\" ProcessDuplexNaming=\"0\" ProcessDuplexNoSeparator=\"0\" ProcessBlipNaming=\"0\" ProcessBlipSizeMedium=\"1\" ProcessBlipSizeLarge=\"1\" ProcessFileStartNumber=\"1\" ProcessBlipSaveSeparateFolders=\"0\" ProcessBlipSepFolderTwoDeep=\"0\" ProcessBlipNoMediumBlips=\"0\" ProcessBlipSaveMultiPageFiles=\"0\" ProcessMediumBlipRenumbering=\"0\" ProcessMediumBlipStartNumber=\"1\" ProcessLargeBlipStartNumber=\"1\" ProcessAbsolutMaxFrameLength=\"32768\" ProcessFicheSeparateFolders=\"0\" ProcesscheckBoxFicheCompleteFile=\"0\" ProcessFicheSeparateBy=\"0\" ProcessFicheDualKeyEntry=\"0\" ProcessFicheFindRowColOrder=\"0\" ProcessFicheUseFicheNumbers=\"0\" ProcessFicheSaveTitlescans=\"0\" ProcessFicheSaveTitlescansForceGray=\"0\" ProcessFicheSavePrescans=\"0\" ProcessFicheStartLetter=\"A\" ProcessFicheMultiPageFiles=\"0\" ProcessFicheNamingStyle=\"0\" ProcessMarkerSaveSeparateFolders=\"1\" ProcessMarkerSaveMultiPageFiles=\"0\" ProcessMarkerSaveMarkerFrames=\"1\" ProcessReverseOrderNaming=\"0\" ProcessMarkerUserSpecified=\"0\" ProcessMarkerReuseMarkerNames=\"0\" ProcessMarkerContinueCount=\"0\" ProcessDuoNaming=\"0\" ProcessSeparator=\"-\" ProcessReverseUpperLower=\"0\" ProcessReverseLeftRight=\"0\" ProcessISIlog=\"0\"";

    // ------------------------------------------------------------------ load

    /// <summary>Loads only the frames of a QPF/SLF (roll XML, or the older INI layout).</summary>
    public static bool TryLoadFrames(string fileName, out List<FrameRecord> frames)
    {
        frames = [];
        if (!File.Exists(fileName)) return false;
        try
        {
            var doc = XDocument.Load(fileName);
            if (doc.Root is { Name.LocalName: "Roll" } rollNode)
            {
                var detection = FindScannerSettings(rollNode, "QP")?.Element("DetectionSettings");
                frames = LoadFramesFromDetection(detection);
                if (frames.Count > 0) return true;
            }
        }
        catch (XmlException) { /* not XML: try INI below */ }
        frames = LoadIniFrames(fileName);
        return frames.Count > 0;
    }

    /// <summary>Loads a QPF or SLF as a full project (roll + frames + notes).</summary>
    public static bool TryLoadProject(string fileName, out Project project)
    {
        project = new Project();
        if (!File.Exists(fileName)) return false;
        if (TryLoadProjectFromRollXml(fileName, project)) return true;

        // Old INI-style SLF: frames only.
        project = new Project();
        var roll = project.Roll;
        roll.RollName = Path.GetFileNameWithoutExtension(fileName);
        roll.BasePath = RollPaths.WithTrailingSeparator(Path.GetDirectoryName(Path.GetFullPath(fileName)) ?? "");
        roll.PreviewBasePath = roll.BasePath;
        roll.PreviewSourceBasePath = roll.BasePath;
        project.Frames = LoadIniFrames(fileName);
        project.SourceIdfPath = IniSourceIdf(fileName);
        roll.Loaded = project.Frames.Count > 0;
        return roll.Loaded;
    }

    /// <summary>The IDF an SLF was created from, or "".</summary>
    public static string SlfSourceIdfPath(string fileName)
    {
        if (!File.Exists(fileName)) return "";
        try
        {
            var doc = XDocument.Load(fileName);
            if (doc.Root is { Name.LocalName: "Roll" } root)
                return XmlAttr.Str(root.Element("StriplightSettings"), "SourceIDFPath");
        }
        catch (XmlException) { }
        return IniSourceIdf(fileName);
    }

    private static bool TryLoadProjectFromRollXml(string fileName, Project project)
    {
        XDocument doc;
        try { doc = XDocument.Load(fileName); }
        catch (XmlException) { return false; }

        var rollNode = doc.Root;
        if (rollNode is null || rollNode.Name.LocalName != "Roll") return false;
        var scanner = FindScannerSettings(rollNode, "1") ?? FindScannerSettings(rollNode, "QP");
        if (scanner is null) return false;

        var roll = project.Roll;
        roll.RollName = XmlAttr.Str(rollNode, "RollName");
        roll.RollNumber = XmlAttr.Str(rollNode, "RollNumber");
        roll.RollId = XmlAttr.Str(rollNode, "RollID");
        roll.BasePath = RollPaths.WithTrailingSeparator(Path.GetDirectoryName(Path.GetFullPath(fileName)) ?? "");
        roll.PreviewBasePath = roll.BasePath;
        roll.PreviewSourceBasePath = roll.BasePath;
        if (roll.RollName.Length == 0 || roll.RollName.Equals("none", StringComparison.OrdinalIgnoreCase))
            roll.RollName = Path.GetFileNameWithoutExtension(fileName);

        IdfParser.ReadScannerSettings(scanner, roll);
        roll.PreviewSourceFolder = roll.PreviewFolder;

        var s = rollNode.Element("StriplightSettings");
        if (s is not null)
        {
            project.SourceIdfPath = XmlAttr.Str(s, "SourceIDFPath");
            roll.AdjustMethod = XmlAttr.Int(s, "AdjustMethod", roll.AdjustMethod);
            roll.AdjustFlags = XmlAttr.Int(s, "AdjustFlags", roll.AdjustFlags);
            roll.AdjustContrast = XmlAttr.Int(s, "AdjustContrast", roll.AdjustContrast);
            roll.AdjustBrightness = XmlAttr.Int(s, "AdjustBrightness", roll.AdjustBrightness);
            roll.AdjustGamma = XmlAttr.Int(s, "AdjustGamma", roll.AdjustGamma);
            roll.AdjustStrength = XmlAttr.Int(s, "AdjustStrength", roll.AdjustStrength);
            roll.Sharpness = XmlAttr.Int(s, "Sharpness", roll.Sharpness);
            roll.SharpnessMode = XmlAttr.Int(s, "SharpnessMode", roll.SharpnessMode);
            roll.ExportNamingMode = XmlAttr.Int(s, "ExportNamingMode", roll.ExportNamingMode);
            roll.ArchiveList = DecodeSlfText(XmlAttr.Str(s, "ArchiveList", roll.ArchiveList));
            roll.ReportMicrofilm = XmlAttr.Str(s, "ReportMicrofilm", roll.ReportMicrofilm);
            roll.ExportGrayscale = XmlAttr.Bool(s, "ExportGrayscale", roll.ExportGrayscale);
            roll.ExportProgressive = XmlAttr.Bool(s, "ExportProgressive", roll.ExportProgressive);
            roll.ExportEncoder = XmlAttr.Int(s, "ExportEncoder", roll.ExportEncoder);
        }
        project.Notes = rollNode.Element("StriplightNotes")?.Value ?? "";
        project.Roll.StriplightState = rollNode.Element("StriplightState")?.Value ?? "";

        roll.Normalise();

        var detection = FindScannerSettings(rollNode, "QP")?.Element("DetectionSettings");
        if (detection is not null)
        {
            roll.DetectionThreshold = XmlAttr.Int(detection, "DetectionThreshold", 100);
            roll.DetectMinWidth = XmlAttr.Int(detection, "DetectMinWidth", 252);
            roll.DetectMinLength = XmlAttr.Int(detection, "DetectMinLength", 252);
        }
        project.Frames = LoadFramesFromDetection(detection);
        roll.Loaded = true;
        return true;
    }

    private static XElement? FindScannerSettings(XElement rollNode, string id)
    {
        XElement? first = null;
        foreach (var c in rollNode.Elements("ScannerSettings"))
        {
            first ??= c;
            if (string.Equals(XmlAttr.Str(c, "ID"), id, StringComparison.OrdinalIgnoreCase)) return c;
        }
        return first;
    }

    private static List<FrameRecord> LoadFramesFromDetection(XElement? detection)
    {
        var frames = new List<FrameRecord>();
        if (detection is null) return frames;
        foreach (var c in detection.Elements("Frame"))
        {
            int flip = XmlAttr.Int(c, "PerFrameFlip", 0);
            var f = new FrameRecord
            {
                LeadEdge = XmlAttr.Int64(c, "LeadEdge"),
                TrailEdge = XmlAttr.Int64(c, "TrailEdge"),
                LeftEdge = XmlAttr.Int(c, "LeftEdge"),
                RightEdge = XmlAttr.Int(c, "RightEdge"),
                IsMarker = XmlAttr.Bool(c, "IsMarker"),
                IsSuggested = XmlAttr.Bool(c, "IsSuggested"),
                PerFrameBrightness = XmlAttr.Int(c, "PerFrameBrightness", -1),
                PerFrameContrast = XmlAttr.Int(c, "PerFrameContrast", -1),
                PerFrameGamma = XmlAttr.Int(c, "PerFrameGamma", -1),
                CustomBrightness = XmlAttr.Int(c, "CustomBrightness", -1),
                CustomContrast = XmlAttr.Int(c, "CustomContrast", -1),
                CustomGamma = XmlAttr.Int(c, "CustomGamma", -1),
                CustomToneMethod = XmlAttr.Int(c, "CustomToneMethod", -1),
                CustomToneFlags = XmlAttr.Int(c, "CustomToneFlags", 0),
                CustomStrength = XmlAttr.Int(c, "CustomStrength", -1),
                Rotation = XmlAttr.Int(c, "PerFrameRotate", XmlAttr.Int(c, "Rotation", 0)),
                Negative = XmlAttr.Bool(c, "Negative"),
            };
            f.FlipH = (flip & 1) != 0 || XmlAttr.Bool(c, "FlipH");
            f.FlipV = (flip & 2) != 0 || XmlAttr.Bool(c, "FlipV");
            f.HasOverride = XmlAttr.Bool(c, "HasOverride") || f.Rotation != 0 || flip != 0 ||
                            f.PerFrameBrightness != -1 || f.PerFrameContrast != -1 || f.PerFrameGamma != -1;
            if (!f.IsPersistable) continue;
            f.Index = frames.Count;
            frames.Add(f);
        }
        return frames;
    }

    // ----------------------------------------------------- legacy INI layout

    private static Dictionary<string, Dictionary<string, string>> ReadIni(string fileName)
    {
        var result = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, string>? section = null;
        foreach (var raw in File.ReadLines(fileName))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line[0] is ';' or '#') continue;
            if (line[0] == '[' && line[^1] == ']')
            {
                string name = line[1..^1].Trim();
                if (!result.TryGetValue(name, out section))
                    result[name] = section = new(StringComparer.OrdinalIgnoreCase);
                continue;
            }
            int eq = line.IndexOf('=');
            if (eq > 0 && section is not null) section[line[..eq].Trim()] = line[(eq + 1)..].Trim();
        }
        return result;
    }

    private static string IniGet(Dictionary<string, Dictionary<string, string>> ini, string sec, string key, string def = "") =>
        ini.TryGetValue(sec, out var s) && s.TryGetValue(key, out var v) ? v : def;

    private static bool IniBool(string v) => v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase);

    private static List<FrameRecord> LoadIniFrames(string fileName)
    {
        var frames = new List<FrameRecord>();
        try
        {
            var ini = ReadIni(fileName);
            int.TryParse(IniGet(ini, "Roll", "FrameCount", "0"), out int total);
            for (int i = 0; i < total; i++)
            {
                string sec = "Frame_" + i.ToString(CultureInfo.InvariantCulture);
                long.TryParse(IniGet(ini, sec, "LeadEdge", "0"), out long lead);
                long.TryParse(IniGet(ini, sec, "TrailEdge", "0"), out long trail);
                int.TryParse(IniGet(ini, sec, "LeftEdge", "0"), out int left);
                int.TryParse(IniGet(ini, sec, "RightEdge", "0"), out int right);
                var f = new FrameRecord
                {
                    LeadEdge = lead, TrailEdge = trail, LeftEdge = left, RightEdge = right,
                    IsMarker = IniBool(IniGet(ini, sec, "IsMarker")),
                    IsSuggested = IniBool(IniGet(ini, sec, "IsSuggested")),
                };
                if (!f.IsPersistable) continue;
                f.Index = frames.Count;
                frames.Add(f);
            }
        }
        catch (IOException) { frames.Clear(); }
        return frames;
    }

    private static string IniSourceIdf(string fileName)
    {
        try
        {
            var ini = ReadIni(fileName);
            return IniGet(ini, "Striplight", "Format").Equals("SLF", StringComparison.OrdinalIgnoreCase)
                ? IniGet(ini, "Source", "IDFPath") : "";
        }
        catch (IOException) { return ""; }
    }
}

using System.Globalization;
using System.Net;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;
using Striplight.Core.Model;

namespace Striplight.Core.Export;

/// <summary>One report row: one series folder of this project.</summary>
public sealed record ProjectReportRow(
    string Identifier, IReadOnlyList<string> Signatures, string SignatureList, string Microfilm,
    int Units, int Files, long Bytes, string Gb, string Directory, int MissingFiles);

public sealed record ProjectReport(
    IReadOnlyList<ProjectReportRow> Rows, int Units, int Files, long Bytes, string Gb,
    int ExpectedFiles, int MissingFiles, int FramesWithoutRow);

/// <summary>
/// The handover report of one processed roll (the StripLedger series report, per project):
/// one row per series folder written by this roll in archive-list mode, with its signatures
/// (natural order, consecutive numbers as ranges), the roll's microfilm numbers, the number of
/// units, files and GB, and the series folder. Only this roll's own files are counted, checked
/// on disk, so a series folder shared with other rolls never mixes their files in.
/// </summary>
public static class ProjectReportBuilder
{
    private static readonly CultureInfo Polish = CultureInfo.GetCultureInfo("pl-PL");

    /// <summary>"123-321_400_405-500" or "123-321 400" → "123-321; 400; 405-500".</summary>
    public static string FormatMicrofilm(string? folderName) =>
        string.Join("; ", Regex.Split(folderName ?? "", @"[_\s;]+").Where(p => p.Length > 0));

    /// <summary>Bytes / 1,000,000,000, rounded once to two places with a decimal comma (StripLedger rule).</summary>
    public static string Gb(long bytes) =>
        decimal.Round(bytes / 1_000_000_000m, 2, MidpointRounding.AwayFromZero).ToString("0.00", Polish);

    /// <param name="fileSize">Size of an exported file, or null when it is not on disk.</param>
    public static ProjectReport Build(IReadOnlyList<FrameRecord> frames, NamingOptions naming, string microfilm,
        Func<string, long?> fileSize)
    {
        if (naming.Mode != 1) throw new InvalidOperationException("The report needs archive-list naming.");

        var groups = new Dictionary<string, (string Identifier, HashSet<string> Signatures, int Files, long Bytes, int Missing)>(StringComparer.OrdinalIgnoreCase);
        var order = new List<string>();
        int expected = 0, missing = 0, withoutRow = 0;
        for (int i = 0; i < frames.Count; i++)
        {
            ExportPath p;
            try { p = ExportNaming.PathForFrame(frames, i, naming); }
            catch (InvalidOperationException) { withoutRow++; continue; }
            expected++;
            string seriesDir = Path.GetDirectoryName(p.FolderPath) ?? p.FolderPath;
            string signature = Path.GetFileName(p.FolderPath);
            if (!groups.TryGetValue(seriesDir, out var g))
            {
                string rel = Path.GetRelativePath(naming.OutputRoot, seriesDir);
                g = (rel == "." ? "" : rel.Replace('/', '\\'), new HashSet<string>(StringComparer.OrdinalIgnoreCase), 0, 0, 0);
                order.Add(seriesDir);
            }
            g.Signatures.Add(signature);
            if (fileSize(p.FullPath) is long size) { g.Files++; g.Bytes += size; }
            else { g.Missing++; missing++; }
            groups[seriesDir] = g;
        }

        var rows = order
            .Select(dir =>
            {
                var g = groups[dir];
                var sigs = g.Signatures.OrderBy(s => s, NaturalComparer.Instance).ToList();
                return new ProjectReportRow(g.Identifier, sigs, SignatureRanges.Format(sigs), microfilm,
                    sigs.Count, g.Files, g.Bytes, Gb(g.Bytes), dir, g.Missing);
            })
            .OrderBy(r => r.Identifier, NaturalComparer.Instance)
            .ThenBy(r => r.Directory, StringComparer.OrdinalIgnoreCase)
            .ToList();
        long bytes = rows.Sum(r => r.Bytes);
        return new ProjectReport(rows, rows.Sum(r => r.Units), rows.Sum(r => r.Files), bytes, Gb(bytes),
            expected, missing, withoutRow);
    }

    /// <summary>The grid copied to Excel: optional header row, then one line per row.</summary>
    public static ClipboardPayload ToClipboard(ProjectReport report, IReadOnlyList<string>? headers)
    {
        var grid = new List<string[]>();
        if (headers is not null) grid.Add(headers.ToArray());
        foreach (var r in report.Rows)
            grid.Add([r.Identifier, r.SignatureList, r.Microfilm,
                r.Units.ToString(CultureInfo.InvariantCulture), r.Files.ToString(CultureInfo.InvariantCulture), r.Gb, r.Directory]);
        return ExcelClipboard.FromGrid(grid, new HashSet<int> { 3, 4, 5 }, headers is not null);
    }
}

/// <summary>
/// Natural ordering for display (port of StripLedger.Core.NaturalComparer): digit runs compare by
/// value, exact ties fall back to ordinal so "01" and "1" stay distinct and deterministic.
/// </summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? a, string? b)
    {
        if (ReferenceEquals(a, b)) return 0;
        if (a is null) return -1;
        if (b is null) return 1;
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsAsciiDigit(a[i])) i++;
                while (j < b.Length && char.IsAsciiDigit(b[j])) j++;
                var da = a.AsSpan(si, i - si).TrimStart('0');
                var db = b.AsSpan(sj, j - sj).TrimStart('0');
                if (da.Length != db.Length) return da.Length.CompareTo(db.Length);
                int cmp = da.SequenceCompareTo(db);
                if (cmp != 0) return cmp;
                continue;
            }
            char ca = char.ToUpperInvariant(a[i]), cb = char.ToUpperInvariant(b[j]);
            if (ca != cb) return ca.CompareTo(cb);
            i++; j++;
        }
        int rest = (a.Length - i).CompareTo(b.Length - j);
        return rest != 0 ? rest : string.CompareOrdinal(a, b);
    }
}

/// <summary>
/// Signature list with runs of consecutive numbers as ranges: 1-4; 6-7; 11-13 (port of StripLedger).
/// A number joins a range only if written the same way (007-009, 9-10; not 09 and 010); names with
/// letters stay as they are, so the text always reads back to the same signatures.
/// </summary>
public static class SignatureRanges
{
    public static string Format(IEnumerable<string> naturallySorted)
    {
        var parts = new List<string>();
        string? first = null, last = null;
        void Flush()
        {
            if (first is null) return;
            parts.Add(first == last ? first : $"{first}-{last}");
            first = last = null;
        }
        foreach (string s in naturallySorted)
        {
            if (first is not null && Follows(last!, s)) { last = s; continue; }
            Flush();
            if (IsNumber(s)) first = last = s;
            else parts.Add(s);
        }
        Flush();
        return string.Join("; ", parts);
    }

    private static bool IsNumber(string s) => s.Length > 0 && s.All(char.IsAsciiDigit);

    private static bool Follows(string previous, string next)
    {
        if (!IsNumber(next) || BigInteger.Parse(next) != BigInteger.Parse(previous) + 1) return false;
        bool padded = previous[0] == '0' || next[0] == '0';
        return !padded || previous.Length == next.Length;
    }
}

public sealed record ClipboardPayload(string Tsv, byte[] CfHtml, bool Normalized);

/// <summary>
/// Excel clipboard (port of StripLedger.Core.ExcelClipboard): Unicode TSV with CRLF plus a CF_HTML
/// table that marks text columns as text, so "1; 2", "5-6" or "007" are not turned into numbers or
/// dates. Tabs and line breaks become spaces; values Excel could evaluate get a leading apostrophe.
/// </summary>
public static class ExcelClipboard
{
    public static ClipboardPayload FromGrid(IReadOnlyList<string[]> grid, IReadOnlySet<int> numericColumns, bool firstRowIsHeader)
    {
        bool normalized = false;
        var clean = new List<string[]>(grid.Count);
        for (int r = 0; r < grid.Count; r++)
        {
            bool header = firstRowIsHeader && r == 0;
            var cells = new string[grid[r].Length];
            for (int c = 0; c < cells.Length; c++)
                cells[c] = !header && numericColumns.Contains(c) ? grid[r][c] : Sanitize(grid[r][c], ref normalized);
            clean.Add(cells);
        }
        var tsv = new StringBuilder();
        foreach (var row in clean) tsv.Append(string.Join('\t', row)).Append("\r\n");
        return new ClipboardPayload(tsv.ToString(), WrapCfHtml(HtmlTable(clean, numericColumns, firstRowIsHeader)), normalized);
    }

    public static string Sanitize(string value, ref bool normalized)
    {
        string v = value;
        if (v.AsSpan().IndexOfAny('\t', '\r', '\n') >= 0)
        {
            v = v.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ');
            normalized = true;
        }
        if (v.Length > 0 && v[0] is '=' or '+' or '-' or '@')
        {
            v = "'" + v;
            normalized = true;
        }
        return v;
    }

    private static string HtmlTable(List<string[]> grid, IReadOnlySet<int> numeric, bool firstRowIsHeader)
    {
        var sb = new StringBuilder("<table>");
        for (int r = 0; r < grid.Count; r++)
        {
            sb.Append("<tr>");
            for (int c = 0; c < grid[r].Length; c++)
            {
                string text = WebUtility.HtmlEncode(grid[r][c]);
                if (!(firstRowIsHeader && r == 0) && numeric.Contains(c)) sb.Append("<td>").Append(text).Append("</td>");
                else sb.Append("<td style=\"mso-number-format:'\\@'\">").Append(text).Append("</td>");
            }
            sb.Append("</tr>");
        }
        return sb.Append("</table>").ToString();
    }

    /// <summary>CF_HTML envelope; offsets are byte offsets into the UTF-8 payload.</summary>
    public static byte[] WrapCfHtml(string fragment)
    {
        const string header = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        const string pre = "<html><head><meta charset=\"utf-8\"></head><body><!--StartFragment-->";
        const string post = "<!--EndFragment--></body></html>";
        int headerLength = Encoding.UTF8.GetByteCount(string.Format(CultureInfo.InvariantCulture, header, 0, 0, 0, 0));
        int startHtml = headerLength;
        int startFragment = startHtml + Encoding.UTF8.GetByteCount(pre);
        int endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
        int endHtml = endFragment + Encoding.UTF8.GetByteCount(post);
        return Encoding.UTF8.GetBytes(
            string.Format(CultureInfo.InvariantCulture, header, startHtml, endHtml, startFragment, endFragment)
            + pre + fragment + post);
    }
}

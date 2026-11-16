namespace Striplight.Core.Export;

/// <summary>
/// "Build from folders" (port of TMainForm.OnBuildArchiveListFromFolders): one archive-list
/// row per leaf folder under a root, in natural order, written as ";part;part;part" with the
/// folder names relative to the root. Folder names containing ';' cannot be expressed in the
/// list and are skipped.
/// </summary>
public static class ArchiveFolders
{
    public sealed record Result(List<string> Rows, int SkippedNames);

    public static Result Build(string root)
    {
        var rows = new List<string>();
        int skipped = 0;

        void Scan(string dir, List<string> relative)
        {
            var children = new List<string>();
            IEnumerable<string> subdirs;
            try { subdirs = Directory.EnumerateDirectories(dir); }
            catch (Exception e) when (e is UnauthorizedAccessException or IOException) { subdirs = []; }
            foreach (string d in subdirs)
            {
                string name = Path.GetFileName(d);
                if (name.Contains(';')) skipped++;
                else children.Add(name);
            }
            children.Sort(NaturalCompare);
            if (children.Count == 0 && relative.Count > 0)
            {
                rows.Add(";" + string.Join(";", relative));
                return;
            }
            foreach (string c in children) Scan(Path.Combine(dir, c), [.. relative, c]);
        }

        Scan(Path.GetFullPath(root), []);
        return new Result(rows, skipped);
    }

    /// <summary>Case-insensitive comparison where digit runs compare as numbers ("2" before "10").</summary>
    public static int NaturalCompare(string? a, string? b)
    {
        a ??= ""; b ??= "";
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                string na = a[si..i].TrimStart('0'), nb = b[sj..j].TrimStart('0');
                int c = na.Length != nb.Length ? na.Length.CompareTo(nb.Length) : string.CompareOrdinal(na, nb);
                if (c != 0) return c;
            }
            else
            {
                int c = char.ToUpperInvariant(a[i]).CompareTo(char.ToUpperInvariant(b[j]));
                if (c != 0) return c;
                i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}

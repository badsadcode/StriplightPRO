using Striplight.Core.Model;

namespace Striplight.Core.Editing;

/// <summary>
/// Frame list edits that change the list structure. Simple per-frame edits (drag, resize)
/// are patched in place by the UI; everything here re-sorts and refreshes size flags.
/// </summary>
public static class FrameEditor
{
    /// <summary>Oversize factor of the median frame length (Lazarus: 1 + percent / 100; huge = off).</summary>
    public static double OversizeFactor { get; private set; } = 1.5;
    /// <summary>Undersize factor of the median frame length (Lazarus: 1 - percent / 100; 0 = off).</summary>
    public static double UndersizeFactor { get; private set; } = 0.5;

    /// <summary>
    /// Size check like the Lazarus "Detect Oversized / Undersized Frames" box: a frame is
    /// oversized when it is more than <paramref name="overPercent"/> % longer than the median
    /// frame (0..200), undersized when it is more than <paramref name="underPercent"/> % shorter
    /// (0..99). A switched-off check flags nothing.
    /// </summary>
    public static void SetSizeRules(bool overOn, int overPercent, bool underOn, int underPercent)
    {
        OversizeFactor = overOn ? 1.0 + Math.Clamp(overPercent, 0, 200) / 100.0 : 9999.0;
        UndersizeFactor = underOn ? 1.0 - Math.Clamp(underPercent, 0, 99) / 100.0 : 0.0;
    }

    public static void Refresh(List<FrameRecord> frames)
    {
        FrameList.SortByPosition(frames);
        FrameList.MarkOversizedUndersized(frames, FrameList.CalculateStats(frames, OversizeFactor, UndersizeFactor));
    }

    public static void Delete(List<FrameRecord> frames, IEnumerable<int> indices)
    {
        foreach (int i in indices.Distinct().OrderDescending())
            if (i >= 0 && i < frames.Count) frames.RemoveAt(i);
        Refresh(frames);
    }

    /// <summary>Sets the marker flag on all given frames, or clears it if they all already have it.</summary>
    public static void ToggleMarker(List<FrameRecord> frames, IEnumerable<int> indices)
    {
        var sel = indices.Where(i => i >= 0 && i < frames.Count).ToList();
        if (sel.Count == 0) return;
        bool set = !sel.All(i => frames[i].IsMarker);
        foreach (int i in sel)
        {
            frames[i].IsMarker = set;
            if (set) frames[i].IsSuggested = false;
        }
    }

    public static void ClearMarkers(List<FrameRecord> frames)
    {
        foreach (var f in frames) { f.IsMarker = false; f.IsSuggested = false; }
    }

    /// <summary>Adds a frame and returns its index after sorting.</summary>
    public static int Add(List<FrameRecord> frames, FrameRecord frame)
    {
        if (!frame.IsPersistable) throw new ArgumentException("Frame needs a positive width and height.");
        frames.Add(frame);
        Refresh(frames);
        return frames.IndexOf(frame);
    }

    /// <summary>Replaces the frames that start inside [fromStrip, toStrip] with newly detected ones.</summary>
    public static void ReplaceDetectedRange(List<FrameRecord> frames, IEnumerable<FrameRecord> detected,
        int fromStrip, int toStrip, int lengthLines)
    {
        frames.RemoveAll(f => f.LeadStrip(lengthLines) >= fromStrip && f.LeadStrip(lengthLines) <= toStrip);
        frames.AddRange(detected);
        Refresh(frames);
    }

    /// <summary>Clears per-frame overrides (rotation/flip/negative and tone) on the given frames.</summary>
    public static void ClearOverrides(List<FrameRecord> frames, IEnumerable<int> indices)
    {
        foreach (int i in indices)
        {
            if (i < 0 || i >= frames.Count) continue;
            var f = frames[i];
            f.HasOverride = false; f.Rotation = 0; f.FlipH = false; f.FlipV = false; f.Negative = false;
            f.ClearTone();
        }
    }

    // ---- Lazarus frame tools (same semantics as TMainForm.OnMergeAdjacent etc.) ----

    private static void Union(FrameRecord a, FrameRecord b)
    {
        a.LeadEdge = Math.Min(a.LeadEdge, b.LeadEdge);
        a.TrailEdge = Math.Max(a.TrailEdge, b.TrailEdge);
        a.LeftEdge = Math.Min(a.LeftEdge, b.LeftEdge);
        a.RightEdge = Math.Max(a.RightEdge, b.RightEdge);
    }

    /// <summary>
    /// E: merges the selected frames in pairs (1st+2nd, 3rd+4th, ...) into their bounding box.
    /// Returns the frames to keep selected.
    /// </summary>
    public static List<FrameRecord> MergePairs(List<FrameRecord> frames, IEnumerable<int> indices)
    {
        var sel = indices.Where(i => i >= 0 && i < frames.Count).Distinct().Order().Select(i => frames[i]).ToList();
        var keep = new List<FrameRecord>();
        for (int k = 0; k + 1 < sel.Count; k += 2)
        {
            Union(sel[k], sel[k + 1]);
            frames.Remove(sel[k + 1]);
            keep.Add(sel[k]);
        }
        if (sel.Count % 2 == 1) keep.Add(sel[^1]);
        Refresh(frames);
        return keep;
    }

    /// <summary>J: repeatedly combines selected frames that overlap along the film.</summary>
    public static List<FrameRecord> CombineOverlapping(List<FrameRecord> frames, IEnumerable<int> indices)
    {
        var sel = indices.Where(i => i >= 0 && i < frames.Count).Distinct().Order().Select(i => frames[i]).ToList();
        bool changed;
        do
        {
            changed = false;
            for (int i = 0; i < sel.Count && !changed; i++)
                for (int j = i + 1; j < sel.Count; j++)
                {
                    if (sel[i].LeadEdge < sel[j].TrailEdge && sel[i].TrailEdge > sel[j].LeadEdge)
                    {
                        Union(sel[i], sel[j]);
                        frames.Remove(sel[j]);
                        sel.RemoveAt(j);
                        changed = true;
                        break;
                    }
                }
        } while (changed);
        Refresh(frames);
        return sel;
    }

    /// <summary>S: splits each selected frame into <paramref name="parts"/> equal parts along the film.</summary>
    public static List<FrameRecord> Split(List<FrameRecord> frames, IEnumerable<int> indices, int parts)
    {
        var created = new List<FrameRecord>();
        if (parts < 2) return created;
        var sel = indices.Where(i => i >= 0 && i < frames.Count).Distinct().Select(i => frames[i]).ToList();
        foreach (var f in sel)
        {
            long part = Math.Max(1, f.Height / parts);
            long trail = f.TrailEdge;
            for (int k = 0; k < parts; k++)
            {
                var p = k == 0 ? f : f.Clone();
                p.LeadEdge = f.LeadEdge + k * part;
                p.TrailEdge = k == parts - 1 ? trail : f.LeadEdge + (k + 1) * part;
                if (k > 0) { p.IsMarker = false; frames.Add(p); }
                created.Add(p); // the first part is the original frame and keeps its marker
            }
        }
        Refresh(frames);
        return created;
    }

    /// <summary>Z: toggles the suggested-marker flag of a single frame.</summary>
    public static void ToggleSuggested(List<FrameRecord> frames, int index)
    {
        if (index >= 0 && index < frames.Count) frames[index].IsSuggested = !frames[index].IsSuggested;
    }

    /// <summary>F/G: next or previous folder marker after <paramref name="from"/>, wrapping around; -1 if none.</summary>
    public static int FindMarker(IReadOnlyList<FrameRecord> frames, int from, bool forward)
    {
        int n = frames.Count;
        for (int k = 1; k <= n; k++)
        {
            int i = ((forward ? from + k : from - k) % n + n) % n;
            if (frames[i].IsMarker) return i;
        }
        return -1;
    }
}

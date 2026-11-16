using Striplight.Core.Model;

namespace Striplight.Core.Editing;

/// <summary>
/// Frame repair tools from the Lazarus edition (Framing tab): close gaps, join close
/// fragments, expand, trim and folder sections. Same semantics as TMainForm.OnCloseSelectedGaps,
/// OnJoinCloseSelected, OnExpandSelected, OnApplyTrim, Select/DeleteMarkerFrameSection.
/// Every method expects frames sorted by position and returns the frames to keep selected.
/// </summary>
public static class FrameRepair
{
    private static List<int> Sorted(IEnumerable<int> indices, int count) =>
        indices.Where(i => i >= 0 && i < count).Distinct().Order().ToList();

    /// <summary>Fill gaps: neighbouring selected frames with a gap meet in the middle of it.</summary>
    public static (int Changed, List<FrameRecord> Keep) CloseGaps(List<FrameRecord> frames, IEnumerable<int> selected)
    {
        var r = CloseGaps(frames, selected, long.MaxValue);
        return (r.Changed, r.Keep);
    }

    /// <summary>
    /// Fill gaps with a limit: gaps wider than <paramref name="maxGap"/> lines are left alone
    /// (blank shots or empty film inside a signature), so two pages are never stretched across them.
    /// </summary>
    public static (int Changed, int Skipped, List<FrameRecord> Keep) CloseGaps(List<FrameRecord> frames, IEnumerable<int> selected, long maxGap)
    {
        var sel = Sorted(selected, frames.Count).ToHashSet();
        int changed = 0, skipped = 0;
        for (int i = 0; i < frames.Count - 1; i++)
        {
            if (!sel.Contains(i) || !sel.Contains(i + 1) || frames[i].TrailEdge >= frames[i + 1].LeadEdge) continue;
            if (frames[i + 1].LeadEdge - frames[i].TrailEdge > maxGap) { skipped++; continue; }
            long mid = (frames[i].TrailEdge + frames[i + 1].LeadEdge) / 2;
            frames[i].TrailEdge = mid;
            frames[i + 1].LeadEdge = mid;
            changed++;
        }
        var keep = sel.Select(i => frames[i]).ToList();
        FrameEditor.Refresh(frames);
        return (changed, skipped, keep);
    }

    /// <summary>
    /// The automatic gap limit: <paramref name="factor"/> × the typical (median) gap between the
    /// selected neighbouring frames, but never less than 10 % of the typical frame length, so pages
    /// that almost touch still count as normal. Returns -1 when there are no gaps.
    /// </summary>
    public static long AutoGapLimit(IReadOnlyList<FrameRecord> frames, IEnumerable<int> selected, double factor)
    {
        var sel = Sorted(selected, frames.Count).ToHashSet();
        var gaps = new List<long>();
        var lengths = new List<long>();
        foreach (int i in sel) lengths.Add(frames[i].TrailEdge - frames[i].LeadEdge);
        for (int i = 0; i < frames.Count - 1; i++)
            if (sel.Contains(i) && sel.Contains(i + 1) && frames[i + 1].LeadEdge > frames[i].TrailEdge)
                gaps.Add(frames[i + 1].LeadEdge - frames[i].TrailEdge);
        if (gaps.Count == 0) return -1;
        static long Median(List<long> v) { v.Sort(); int n = v.Count; return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2; }
        long medianGap = Median(gaps), medianLength = lengths.Count > 0 ? Median(lengths) : 0;
        return Math.Max((long)Math.Round(medianGap * Math.Max(1.0, factor)), medianLength / 10);
    }

    /// <summary>
    /// Join close: runs of neighbouring selected frames whose gap is at most <paramref name="maxGap"/>
    /// lines become one frame (bounding box; marker/suggested kept, exported only if all were).
    /// </summary>
    public static (int Runs, int Removed, List<FrameRecord> Keep) JoinClose(List<FrameRecord> frames, IEnumerable<int> selected, long maxGap)
    {
        var sel = Sorted(selected, frames.Count).ToHashSet();
        var result = new List<FrameRecord>(frames.Count);
        var keep = new List<FrameRecord>();
        int runs = 0, removed = 0;
        for (int i = 0; i < frames.Count;)
        {
            if (!sel.Contains(i)) { result.Add(frames[i]); i++; continue; }
            var m = frames[i];
            int j = i + 1;
            while (j < frames.Count && sel.Contains(j) && frames[j].LeadEdge - m.TrailEdge <= maxGap)
            {
                var f = frames[j];
                m.LeadEdge = Math.Min(m.LeadEdge, f.LeadEdge);
                m.TrailEdge = Math.Max(m.TrailEdge, f.TrailEdge);
                m.LeftEdge = Math.Min(m.LeftEdge, f.LeftEdge);
                m.RightEdge = Math.Max(m.RightEdge, f.RightEdge);
                m.IsMarker |= f.IsMarker;
                m.IsSuggested |= f.IsSuggested;
                m.IsExported &= f.IsExported;
                removed++;
                j++;
            }
            if (j > i + 1) runs++;
            result.Add(m);
            keep.Add(m);
            i = j;
        }
        if (removed > 0)
        {
            frames.Clear();
            frames.AddRange(result);
            FrameEditor.Refresh(frames);
        }
        return (runs, removed, keep);
    }

    /// <summary>
    /// Expand (or shrink with negative values) the selected frames: lead/trail along the film,
    /// left/right across it, each clamped to the roll.
    /// </summary>
    public static (int Changed, List<FrameRecord> Keep) Expand(List<FrameRecord> frames, IEnumerable<int> selected,
        RollData roll, int addLead, int addTrail, int addLeft, int addRight)
    {
        var sel = Sorted(selected, frames.Count);
        long maxLine = (long)Math.Max(1, roll.StripCount) * Math.Max(1, roll.LengthLines);
        foreach (int i in sel)
        {
            var f = frames[i];
            long lead = Math.Clamp(f.LeadEdge - addLead, 0, maxLine - 1);
            long trail = Math.Clamp(f.TrailEdge + addTrail, lead + 1, maxLine);
            int left = Math.Clamp(f.LeftEdge - addLeft, 0, Math.Max(0, roll.WidthPixels - 1));
            int right = Math.Clamp(f.RightEdge + addRight, left + 1, roll.WidthPixels);
            f.LeadEdge = lead; f.TrailEdge = trail; f.LeftEdge = left; f.RightEdge = right;
        }
        var keep = sel.Select(i => frames[i]).ToList();
        FrameEditor.Refresh(frames);
        return (sel.Count, keep);
    }

    /// <summary>
    /// Trim: clamps every frame's across-the-film edges into [<paramref name="minLeft"/>, <paramref name="maxRight"/>]
    /// (stored-strip columns). Only frames that stick out are changed.
    /// </summary>
    public static int Trim(List<FrameRecord> frames, int minLeft, int maxRight)
    {
        int changed = 0;
        foreach (var f in frames)
        {
            bool c = false;
            if (minLeft > 0 && f.LeftEdge < minLeft) { f.LeftEdge = minLeft; c = true; }
            if (maxRight > 0 && f.RightEdge > maxRight) { f.RightEdge = maxRight; c = true; }
            if (f.LeftEdge >= f.RightEdge) f.RightEdge = f.LeftEdge + 1;
            if (c) changed++;
        }
        FrameEditor.Refresh(frames);
        return changed;
    }

    /// <summary>
    /// Folder section around a frame: from the folder marker at or before it up to the frame
    /// before the next marker. With <paramref name="includeSuggested"/>, suggested starts count too.
    /// Returns (-1, -1) when there is no marker before the frame.
    /// </summary>
    public static (int Start, int End) Section(IReadOnlyList<FrameRecord> frames, int index, bool includeSuggested)
    {
        bool IsStart(int i) => frames[i].IsMarker || (includeSuggested && frames[i].IsSuggested);
        if (index < 0 || index >= frames.Count) return (-1, -1);
        int start = -1;
        for (int i = index; i >= 0; i--) if (IsStart(i)) { start = i; break; }
        if (start < 0) return (-1, -1);
        int end = frames.Count - 1;
        for (int i = start + 1; i < frames.Count; i++) if (IsStart(i)) { end = i - 1; break; }
        return (start, end);
    }
}

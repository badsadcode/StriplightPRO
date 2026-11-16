using Striplight.Core.Model;

namespace Striplight.Core.Editing;

public sealed record SuggestResult(int Suggested, long GapThreshold);

/// <summary>
/// Folder-marker suggestions from the gaps between frames — exact port of
/// <c>TMainForm.OnSuggestMarkers</c> in the Lazarus edition. A gap that is much larger than
/// the typical gap (median / quartiles / percentile, scaled by the strictness slider) is
/// taken as the start of a new folder; that frame is flagged <see cref="FrameRecord.IsSuggested"/>.
/// </summary>
public static class MarkerSuggester
{
    public const int StrictnessMin = 10, StrictnessMax = 200, StrictnessDefault = 50;

    /// <param name="frames">Frames sorted by position.</param>
    /// <param name="strictness">Slider position 10..200 (higher = fewer suggestions).</param>
    /// <param name="beforeGap">Suggest the frame before the gap instead of the one after it.</param>
    /// <param name="direction">0 = whole roll, -1 = toward the start of the anchor, +1 = toward the end.</param>
    /// <param name="anchor">Anchor frame index for direction -1/+1.</param>
    public static SuggestResult Suggest(List<FrameRecord> frames, int strictness = StrictnessDefault,
        bool beforeGap = false, int direction = 0, int anchor = -1)
    {
        int n = frames.Count - 1;
        if (n < 1) return new SuggestResult(0, 0);

        int clearFrom = 0, clearTo = frames.Count - 1;
        if (direction != 0)
        {
            if (anchor < 0 || anchor >= frames.Count) throw new ArgumentException("Select exactly one frame as the anchor.");
            if (direction < 0) { clearFrom = 0; clearTo = anchor - 1; }
            else { clearFrom = anchor + 1; clearTo = frames.Count - 1; }
            if (clearFrom > clearTo) return new SuggestResult(0, 0);
        }

        var gaps = new long[n];
        var positive = new List<long>(n);
        for (int i = 0; i < n; i++)
        {
            long g = Math.Max(0, frames[i + 1].LeadEdge - frames[i].TrailEdge);
            gaps[i] = g;
            if (g > 0) positive.Add(g);
        }
        if (positive.Count == 0) return new SuggestResult(0, 0);
        positive.Sort();

        long Percentile(double pct)
        {
            int idx = (int)Math.Round((positive.Count - 1) * pct, MidpointRounding.ToEven);
            return positive[Math.Clamp(idx, 0, positive.Count - 1)];
        }

        long median = Percentile(0.50), q1 = Percentile(0.25), q3 = Percentile(0.75), iqr = q3 - q1;
        double range = Math.Max(1, StrictnessMax - StrictnessMin);
        double strict = Math.Clamp((strictness - StrictnessMin) / range, 0, 1);
        double multiplier = 2.0 + strict * 38.0;
        double iqrFactor = 1.0 + strict * 10.0;
        double pctl = Math.Min(0.99, 0.75 + strict * 0.24);

        long medianBased = (long)Math.Round(median * multiplier, MidpointRounding.ToEven);
        long spreadBased = iqr < median / 2
            ? q3 + (long)Math.Round(median / 2 * iqrFactor, MidpointRounding.ToEven)
            : q3 + (long)Math.Round(iqr * iqrFactor, MidpointRounding.ToEven);
        long threshold = Math.Max(Math.Max(medianBased, spreadBased), Percentile(pctl));

        for (int i = clearFrom; i <= clearTo; i++) frames[i].IsSuggested = false;

        int count = 0, lastSuggested = -1_000_000;
        for (int i = 0; i < n; i++)
        {
            if (gaps[i] < threshold || gaps[i] <= 0) continue;
            if (frames[i].IsMarker || frames[i + 1].IsMarker) continue;
            int c = beforeGap ? i : i + 1;
            if (c < 0 || c >= frames.Count) continue;
            if (direction < 0 && c >= anchor) continue;
            if (direction > 0 && c <= anchor) continue;
            if (c <= lastSuggested + 1) continue;
            if (frames[c].IsMarker) continue;
            if (c > 0 && frames[c - 1].IsMarker) continue;
            frames[c].IsSuggested = true;
            lastSuggested = c;
            count++;
        }
        return new SuggestResult(count, threshold);
    }

    /// <summary>Clears every suggestion, or only those on the given frames.</summary>
    public static int ClearSuggested(List<FrameRecord> frames, IEnumerable<int>? only = null)
    {
        int cleared = 0;
        var set = only?.ToHashSet();
        for (int i = 0; i < frames.Count; i++)
            if (frames[i].IsSuggested && (set is null || set.Contains(i))) { frames[i].IsSuggested = false; cleared++; }
        return cleared;
    }

    /// <summary>From the anchor toward <paramref name="direction"/>, clears every Nth suggestion (Lazarus "clear every").</summary>
    public static int ClearSuggestedEvery(List<FrameRecord> frames, int anchor, int direction, int every)
    {
        if (anchor < 0 || anchor >= frames.Count) throw new ArgumentException("Select exactly one frame as the anchor.");
        direction = direction < 0 ? -1 : 1;
        every = Math.Max(1, every);
        int seen = 0, cleared = 0;
        for (int i = anchor + direction; i >= 0 && i < frames.Count; i += direction)
        {
            if (!frames[i].IsSuggested) continue;
            if (++seen % every == 0) { frames[i].IsSuggested = false; cleared++; }
        }
        return cleared;
    }

    /// <summary>Clears the yellow folder markers from the anchor toward the start or end.</summary>
    public static int ClearMarkersToward(List<FrameRecord> frames, int anchor, int direction)
    {
        if (anchor < 0 || anchor >= frames.Count) throw new ArgumentException("Select exactly one frame as the anchor.");
        direction = direction < 0 ? -1 : 1;
        int cleared = 0;
        for (int i = anchor + direction; i >= 0 && i < frames.Count; i += direction)
            if (frames[i].IsMarker) { frames[i].IsMarker = false; cleared++; }
        return cleared;
    }
}

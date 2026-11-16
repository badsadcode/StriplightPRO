namespace Striplight.Core.Model;

/// <summary>Size statistics used to flag abnormal frames (port of <c>TFrameStats</c>).</summary>
public sealed record FrameStats(
    long MedianHeight,
    int MedianWidth,
    long AverageHeight,
    int AverageWidth,
    double OversizeThreshold,
    double UndersizeThreshold)
{
    public static FrameStats Empty { get; } = new(0, 0, 0, 0, 1.5, 0.5);
}

/// <summary>Frame list helpers from lazarus/uTypes.pas.</summary>
public static class FrameList
{
    /// <summary>Stable sort by lead then trail edge, then renumbers <see cref="FrameRecord.Index"/>.</summary>
    public static void SortByPosition(List<FrameRecord> frames)
    {
        // Insertion sort in the original is stable; OrderBy is stable too.
        var sorted = frames.OrderBy(f => f.LeadEdge).ThenBy(f => f.TrailEdge).ToList();
        frames.Clear();
        frames.AddRange(sorted);
        Renumber(frames);
    }

    public static void Renumber(List<FrameRecord> frames)
    {
        for (int i = 0; i < frames.Count; i++) frames[i].Index = i;
    }

    public static FrameStats CalculateStats(IReadOnlyList<FrameRecord> frames,
        double oversizeThreshold = 1.5, double undersizeThreshold = 0.5)
    {
        int n = frames.Count;
        if (n == 0) return FrameStats.Empty with
        {
            OversizeThreshold = oversizeThreshold,
            UndersizeThreshold = undersizeThreshold,
        };

        var heights = new long[n];
        long totalH = 0, totalW = 0;
        for (int i = 0; i < n; i++)
        {
            heights[i] = frames[i].Height;
            totalH += heights[i];
            totalW += frames[i].Width;
        }
        Array.Sort(heights);
        long median = (n % 2) == 1
            ? heights[n / 2]
            : (heights[n / 2 - 1] + heights[n / 2]) / 2;
        int avgW = (int)(totalW / n);
        // Width median is simplified to the average, as in the original.
        return new FrameStats(median, avgW, totalH / n, avgW, oversizeThreshold, undersizeThreshold);
    }

    public static void MarkOversizedUndersized(IEnumerable<FrameRecord> frames, FrameStats stats)
    {
        if (stats.MedianHeight == 0) return;
        long overH = (long)Math.Round(stats.MedianHeight * stats.OversizeThreshold, MidpointRounding.ToEven);
        long underH = (long)Math.Round(stats.MedianHeight * stats.UndersizeThreshold, MidpointRounding.ToEven);
        foreach (var f in frames)
        {
            long h = f.Height;
            f.IsOversized = h > overH;
            f.IsUndersized = h < underH && h > 0;
        }
    }
}

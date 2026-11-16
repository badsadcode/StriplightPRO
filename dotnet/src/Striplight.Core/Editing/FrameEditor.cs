using Striplight.Core.Model;

namespace Striplight.Core.Editing;

/// <summary>
/// Frame list edits that change the list structure. Simple per-frame edits (drag, resize)
/// are patched in place by the UI; everything here re-sorts and refreshes size flags.
/// </summary>
public static class FrameEditor
{
    public static void Refresh(List<FrameRecord> frames, double oversize = 1.5, double undersize = 0.5)
    {
        FrameList.SortByPosition(frames);
        FrameList.MarkOversizedUndersized(frames, FrameList.CalculateStats(frames, oversize, undersize));
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
            f.PerFrameBrightness = f.PerFrameContrast = f.PerFrameGamma = -1;
            f.CustomBrightness = f.CustomContrast = f.CustomGamma = -1;
        }
    }
}

namespace Striplight.Core.Imaging;

/// <summary>
/// Thread-safe cache of decoded grayscale strips shared by all export workers of one run
/// (port of <c>TGrayStripCache</c>). A strip several workers need is decoded once; strips
/// in use are never evicted; least recently used idle strips go first.
/// </summary>
public sealed class GrayStripCache
{
    private sealed class Entry
    {
        public required string Path;
        public GrayImage? Image;
        public Exception? Error;
        public int RefCount;
        public long LastUse;
        public readonly ManualResetEventSlim Ready = new(false);
    }

    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _items = new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<string, GrayImage> _loader;
    private readonly int _limit;
    private long _clock;

    /// <param name="limit">Idle strips kept in memory.</param>
    /// <param name="loader">Decodes one strip file; defaults to TurboJPEG gray decode.</param>
    public GrayStripCache(int limit, Func<string, GrayImage>? loader = null)
    {
        _limit = Math.Max(1, limit);
        _loader = loader ?? DefaultLoader;
    }

    public static GrayImage DefaultLoader(string path)
    {
        var d = TurboJpeg.DecodeFile(path, TurboJpeg.PixelFormatGray)
                ?? throw new TurboJpegException("Could not decode " + path);
        return new GrayImage(d.Width, d.Height, d.Pixels);
    }

    /// <summary>True when the strip is decoded or being decoded (saves a file-exists round trip on shares).</summary>
    public bool Contains(string path)
    {
        lock (_lock) return _items.ContainsKey(path);
    }

    /// <summary>
    /// Returns a decoded strip, loading it if needed. If another worker is already loading
    /// the same strip this waits for it. Every call must be paired with <see cref="Release"/>.
    /// </summary>
    public GrayImage Acquire(string path)
    {
        Entry e;
        bool mustLoad = false;
        lock (_lock)
        {
            if (!_items.TryGetValue(path, out e!))
            {
                TrimLocked(_limit - 1); // make room first so the cache stays within its limit
                e = new Entry { Path = path };
                _items[path] = e;
                mustLoad = true;
            }
            e.RefCount++;
            e.LastUse = ++_clock;
        }

        if (mustLoad)
        {
            try { e.Image = _loader(path); }
            catch (Exception ex) { e.Error = ex; }
            finally { e.Ready.Set(); }
        }
        else
        {
            e.Ready.Wait();
        }

        if (e.Error is not null)
        {
            lock (_lock)
            {
                e.RefCount--;
                if (_items.TryGetValue(path, out var cur) && cur == e && e.RefCount <= 0) _items.Remove(path);
            }
            throw new IOException("Could not load source image: " + path + " (" + e.Error.Message + ")", e.Error);
        }
        return e.Image!;
    }

    public void Release(string path)
    {
        lock (_lock)
        {
            if (_items.TryGetValue(path, out var e) && e.RefCount > 0) e.RefCount--;
            TrimLocked(_limit);
        }
    }

    /// <summary>Frees every strip that is not in use right now.</summary>
    public void DropUnused()
    {
        lock (_lock) TrimLocked(0);
    }

    private void TrimLocked(int keep)
    {
        while (_items.Count > keep)
        {
            Entry? oldest = null;
            foreach (var e in _items.Values)
                if (e.RefCount == 0 && e.Ready.IsSet && (oldest is null || e.LastUse < oldest.LastUse))
                    oldest = e;
            if (oldest is null) return; // everything left is in use
            _items.Remove(oldest.Path);
            oldest.Ready.Dispose();
        }
    }
}

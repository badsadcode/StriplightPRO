namespace Striplight.Core.Export;

/// <summary>
/// Read-ahead for export on network shares. The strip files an export needs are known in
/// advance (job order), so background readers fetch the next few files into memory while
/// the workers decode, process, encode and write the current ones. The network then stays
/// busy all the time instead of idling while frames are built. Each file is read once;
/// a file the workers ask for before it was fetched is simply read by them.
/// </summary>
public sealed class StripPrefetcher : IDisposable
{
    private sealed class Slot
    {
        public byte[]? Bytes;
        public bool Failed;
        public readonly ManualResetEventSlim Done = new(false);
    }

    private readonly IReadOnlyList<string> _order;
    private readonly Dictionary<string, int> _position = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Slot> _slots = new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<string, byte[]> _read;
    private readonly int _ahead;
    private readonly object _lock = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly List<Thread> _threads = [];
    private int _next;          // next position to fetch
    private int _consumed = -1; // furthest position the workers have taken

    public int Fetched { get; private set; }

    /// <param name="paths">Strip files in the order the export needs them (duplicates are ignored).</param>
    /// <param name="ahead">Files fetched ahead of the workers (memory: about ahead × strip file size).</param>
    /// <param name="readers">Parallel reads (two keep an SMB share busy without flooding it).</param>
    public StripPrefetcher(IEnumerable<string> paths, int ahead = 4, int readers = 2, Func<string, byte[]>? read = null)
    {
        var order = new List<string>();
        foreach (string p in paths)
            if (_position.TryAdd(p, order.Count)) order.Add(p);
        _order = order;
        _ahead = Math.Max(1, ahead);
        _read = read ?? File.ReadAllBytes;
        for (int i = 0; i < Math.Clamp(readers, 1, 8) && order.Count > 0; i++)
        {
            var t = new Thread(Reader) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "StripPrefetch" };
            _threads.Add(t);
            t.Start();
        }
    }

    /// <summary>The strip paths of all jobs, in job order (input for the constructor).</summary>
    public static IEnumerable<string> PathsFor(Model.RollData roll, IReadOnlyList<Model.FrameRecord> frames, IEnumerable<ExportJob> jobs)
    {
        foreach (var job in jobs)
        {
            var f = frames[job.FrameIdx];
            int first = Math.Max(0, f.LeadStrip(roll.LengthLines));
            int last = Math.Min(roll.StripCount - 1, f.TrailStrip(roll.LengthLines));
            for (int s = first; s <= Math.Max(first, last); s++) yield return Model.RollPaths.StripFilePath(roll, s);
        }
    }

    private void Reader()
    {
        while (!_stop.IsCancellationRequested)
        {
            string path;
            Slot slot;
            lock (_lock)
            {
                while (!_stop.IsCancellationRequested && _next < _order.Count && _next > _consumed + _ahead)
                    Monitor.Wait(_lock, 200);
                if (_stop.IsCancellationRequested || _next >= _order.Count) return;
                // Workers already went past this point: whatever they still need there they read themselves.
                if (_next <= _consumed) _next = _consumed + 1;
                if (_next >= _order.Count) return;
                path = _order[_next++];
                if (_slots.ContainsKey(path)) continue;   // taken by a worker already
                slot = new Slot();
                _slots[path] = slot;
            }
            try { slot.Bytes = _read(path); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { slot.Failed = true; }
            lock (_lock) if (slot.Bytes is not null) Fetched++;
            slot.Done.Set();
        }
    }

    /// <summary>True when the file was fetched (saves a file-exists round trip on the share).</summary>
    public bool Has(string path)
    {
        lock (_lock) return _slots.TryGetValue(path, out var s) && s.Done.IsSet && s.Bytes is not null;
    }

    /// <summary>
    /// The file's bytes: from the read-ahead when it has (or is fetching) them, otherwise null
    /// and the caller reads the file itself. Each file is handed out once.
    /// </summary>
    public byte[]? Take(string path)
    {
        Slot? slot;
        lock (_lock)
        {
            if (_position.TryGetValue(path, out int pos) && pos > _consumed)
            {
                _consumed = pos;
                Monitor.PulseAll(_lock);   // readers may move on
            }
            if (!_slots.TryGetValue(path, out slot))
            {
                var reserved = new Slot { Failed = true };   // reserved: the worker reads it
                reserved.Done.Set();
                _slots[path] = reserved;
                return null;
            }
        }
        slot.Done.Wait(_stop.Token);
        byte[]? bytes = slot.Bytes;
        slot.Bytes = null;   // the decoded strip lives in the strip cache from now on
        return bytes;
    }

    public void Dispose()
    {
        _stop.Cancel();
        lock (_lock) Monitor.PulseAll(_lock);
        foreach (var t in _threads) t.Join(2000);
        _stop.Dispose();
    }
}

using System.Diagnostics;
using Striplight.Core.Imaging;
using Striplight.Core.Model;

namespace Striplight.Core.Export;

public enum ExportOutcome { Exported, Skipped, Failed }

public sealed record ExportJob(int OrderIdx, int FrameIdx, string FolderPath, string FullPath);

public sealed record ExportOptions
{
    public int Quality { get; init; } = 100;
    public bool Progressive { get; init; }
    public bool SkipExisting { get; init; }
    public bool AllowPreviewFallback { get; init; }
    /// <summary>Encode to the local temp folder, then copy (helps with flaky network shares).</summary>
    public bool LocalTempStage { get; init; }
    public int Workers { get; init; } = Math.Max(1, Environment.ProcessorCount / 2);
    /// <summary>Decoded strips kept in memory, shared by all workers.</summary>
    public int StripCacheLimit { get; init; } = 4;
    /// <summary>Strip files read ahead in the background (network shares); 0 = off.</summary>
    public int ReadAhead { get; init; } = 4;
}

public sealed record ExportJobResult(ExportJob Job, ExportOutcome Outcome, string? Error, long BuildMs, long SaveMs);

public sealed record ExportSummary(int Exported, int Skipped, int Failed, bool Cancelled, TimeSpan Elapsed,
    IReadOnlyList<ExportJobResult> Failures);

/// <summary>
/// Parallel frame export (replaces <c>TExportWorkerThread</c>). Workers take jobs in order,
/// build each frame on 8-bit gray buffers from a shared strip cache, encode with TurboJPEG
/// in memory, then write the file. Supports pause, cancel and skip-existing.
/// </summary>
public sealed class ExportEngine
{
    private readonly ManualResetEventSlim _running = new(true);

    public bool IsPaused => !_running.IsSet;
    public void Pause() => _running.Reset();
    public void Resume() => _running.Set();

    /// <summary>Builds the job list (and validates naming) for the given frames, in roll order.</summary>
    public static List<ExportJob> BuildJobs(IReadOnlyList<FrameRecord> frames, IEnumerable<int> frameIndices, NamingOptions naming)
    {
        var jobs = new List<ExportJob>();
        foreach (int idx in frameIndices.Distinct().Order())
        {
            var p = ExportNaming.PathForFrame(frames, idx, naming);
            jobs.Add(new ExportJob(jobs.Count, idx, p.FolderPath, p.FullPath));
        }
        return jobs;
    }

    public async Task<ExportSummary> RunAsync(RollData roll, IReadOnlyList<FrameRecord> frames,
        IReadOnlyList<ExportJob> jobs, ProcessSettings process, ExportOptions options,
        IProgress<ExportJobResult>? progress = null, CancellationToken cancel = default)
    {
        var sw = Stopwatch.StartNew();
        // Workers get private copies so the UI can keep editing while an export runs.
        var rollCopy = roll.Clone();
        var frameCopy = frames.Select(f => f.Clone()).ToList();
        // Read-ahead keeps the network busy while workers build frames; each strip file is read once.
        using var prefetch = options.ReadAhead > 0
            ? new StripPrefetcher(StripPrefetcher.PathsFor(rollCopy, frameCopy,
                options.SkipExisting ? jobs.Where(j => !File.Exists(j.FullPath)) : jobs), options.ReadAhead)
            : null;
        var cache = new GrayStripCache(Math.Max(2, options.StripCacheLimit), path =>
        {
            byte[] bytes = prefetch?.Take(path) ?? File.ReadAllBytes(path);
            var d = TurboJpeg.Decode(bytes, TurboJpeg.PixelFormatGray) ?? throw new TurboJpegException("Could not decode " + path);
            return new GrayImage(d.Width, d.Height, d.Pixels);
        });
        var builder = new FrameBuilder(rollCopy, process, cache) { AllowPreviewFallback = options.AllowPreviewFallback };
        Func<string, bool> sourceAvailable = p => cache.Contains(p) || (prefetch?.Has(p) ?? false) || File.Exists(p);

        int next = -1, exported = 0, skipped = 0, failed = 0;
        var failures = new List<ExportJobResult>();
        var createdFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        object folderLock = new();

        void Worker()
        {
            // Below normal: the strip view, preview and the rest of the PC stay responsive while
            // exporting; the export still takes every idle cycle.
            Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
            while (true)
            {
                _running.Wait(cancel);
                cancel.ThrowIfCancellationRequested();
                int i = Interlocked.Increment(ref next);
                if (i >= jobs.Count) return;
                var r = RunJob(jobs[i]);
                switch (r.Outcome)
                {
                    case ExportOutcome.Exported: Interlocked.Increment(ref exported); break;
                    case ExportOutcome.Skipped: Interlocked.Increment(ref skipped); break;
                    default:
                        Interlocked.Increment(ref failed);
                        lock (failures) failures.Add(r);
                        break;
                }
                progress?.Report(r);
            }
        }

        ExportJobResult RunJob(ExportJob job)
        {
            long buildMs = 0, saveMs = 0;
            try
            {
                if (options.SkipExisting && File.Exists(job.FullPath))
                    return new(job, ExportOutcome.Skipped, null, 0, 0);

                var t = Stopwatch.StartNew();
                var img = builder.Build(frameCopy[job.FrameIdx], sourceAvailable);
                var jpeg = TurboJpeg.EncodeGray(img, options.Quality, options.Progressive);
                buildMs = t.ElapsedMilliseconds;

                t.Restart();
                lock (folderLock)
                    if (createdFolders.Add(job.FolderPath)) Directory.CreateDirectory(job.FolderPath);
                WriteFile(job.FullPath, jpeg, options.LocalTempStage);
                saveMs = t.ElapsedMilliseconds;
                return new(job, ExportOutcome.Exported, null, buildMs, saveMs);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or TurboJpegException
                                          or InvalidOperationException or ArgumentException or OutOfMemoryException)
            {
                return new(job, ExportOutcome.Failed, e.Message, buildMs, saveMs);
            }
        }

        int workers = Math.Clamp(options.Workers, 1, Math.Max(1, jobs.Count));
        bool cancelled = false;
        try
        {
            await Task.WhenAll(Enumerable.Range(0, workers)
                .Select(_ => Task.Factory.StartNew(Worker, cancel, TaskCreationOptions.LongRunning, TaskScheduler.Default)));
        }
        catch (OperationCanceledException) { cancelled = true; }
        finally { cache.DropUnused(); }

        return new ExportSummary(exported, skipped, failed, cancelled, sw.Elapsed,
            failures.OrderBy(f => f.Job.OrderIdx).ToList());
    }

    private static void WriteFile(string path, byte[] data, bool localTempStage)
    {
        if (!localTempStage)
        {
            File.WriteAllBytes(path, data);
            return;
        }
        string tempDir = Path.Combine(Path.GetTempPath(), "Striplight_export_temp");
        Directory.CreateDirectory(tempDir);
        string temp = Path.Combine(tempDir, $"frame_{Environment.CurrentManagedThreadId}_{Guid.NewGuid():N}.jpg");
        try
        {
            File.WriteAllBytes(temp, data);
            File.Copy(temp, path, overwrite: true);
        }
        finally
        {
            try { File.Delete(temp); } catch (IOException) { }
        }
    }
}

using System.Collections.Concurrent;
using System.IO;
using Microsoft.Web.WebView2.Core;
using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.Model;
using Striplight.Core.Preview;

namespace Striplight.App.Services;

/// <summary>
/// Serves images to the page from https://img.striplight/:
///   /strip/{index}?v={imageVersion}  — preview strip, tone-adjusted and turned upright
///   /frame/{index}?v={imageVersion}  — one frame exactly as export builds it (downscaled)
/// The version in the query changes whenever tone or orientation changes, so the page
/// never shows a stale image. Rendering runs on the thread pool, a few at a time.
/// </summary>
public sealed class ImageService(AppController controller)
{
    private readonly SemaphoreSlim _gate = new(Math.Clamp(Environment.ProcessorCount - 1, 2, 6));
    private readonly ConcurrentDictionary<string, byte[]> _cache = new();
    private readonly ConcurrentQueue<string> _cacheOrder = new();
    private const int CacheItems = 160;
    // One shared strip cache for frame previews; rebuilt when the roll changes.
    private GrayStripCache _stripCache = new(6);
    private RollData? _stripCacheRoll;

    public async void Handle(CoreWebView2Environment env, CoreWebView2WebResourceRequestedEventArgs e)
    {
        // async void is the WebView2 pattern here: the deferral keeps the request open
        // until a response is set, and must be completed on every path.
        var deferral = e.GetDeferral();
        try
        {
            var uri = new Uri(e.Request.Uri);
            string[] parts = uri.AbsolutePath.Trim('/').Split('/');
            if (parts.Length != 2 || !int.TryParse(parts[1], out int index))
            {
                e.Response = env.CreateWebResourceResponse(null, 404, "Not Found", "");
                return;
            }

            // Gather everything from the UI-thread state before going to the thread pool.
            var roll = controller.Roll;
            var process = controller.Process;
            bool rotateCw = controller.RotateCw;
            string key = uri.PathAndQuery;
            Func<byte[]?> render = parts[0] switch
            {
                "strip" => () => StripPreviewRenderer.RenderStrip(roll, index,
                    process.PreviewOnStrips ? process.Tone : ToneSettings.Neutral, process.Negative, rotateCw),
                // q=full: no downscaling (the preview's "Full quality" / 1:1 view).
                "frame" when controller.SnapshotFrame(index) is { } frame => () =>
                    StripPreviewRenderer.RenderFrame(FrameBuilderFor(roll, process.ToProcessSettings(rotateCw)), frame,
                        uri.Query.Contains("q=full") ? int.MaxValue : 2400),
                _ => () => null,
            };

            byte[]? bytes = _cache.TryGetValue(key, out var hit) ? hit : await Task.Run(() => RenderGated(render));
            if (bytes is null)
            {
                e.Response = env.CreateWebResourceResponse(null, 404, "Not Found", "");
                return;
            }
            Remember(key, bytes);
            e.Response = env.CreateWebResourceResponse(new MemoryStream(bytes), 200, "OK",
                "Content-Type: image/jpeg\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: https://app.striplight");
        }
        catch (Exception ex) when (ex is IOException or TurboJpegException or InvalidOperationException
                                       or UriFormatException or UnauthorizedAccessException)
        {
            e.Response = env.CreateWebResourceResponse(null, 500, "Error", "X-Striplight-Error: " + Sanitise(ex.Message));
        }
        finally
        {
            deferral.Complete();
        }
    }

    private byte[]? RenderGated(Func<byte[]?> render)
    {
        _gate.Wait();
        try { return render(); }
        finally { _gate.Release(); }
    }

    private FrameBuilder FrameBuilderFor(RollData roll, ProcessSettings settings)
    {
        lock (_cache)
        {
            if (!ReferenceEquals(roll, _stripCacheRoll))
            {
                _stripCache = new GrayStripCache(6);
                _stripCacheRoll = roll;
            }
            return new FrameBuilder(roll, settings, _stripCache) { AllowPreviewFallback = true };
        }
    }

    private void Remember(string key, byte[] bytes)
    {
        if (!_cache.TryAdd(key, bytes)) return;
        _cacheOrder.Enqueue(key);
        while (_cacheOrder.Count > CacheItems && _cacheOrder.TryDequeue(out var old)) _cache.TryRemove(old, out _);
    }

    private static string Sanitise(string s) => s.Replace('\r', ' ').Replace('\n', ' ');
}

using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;

namespace Striplight.App.Services;

/// <summary>
/// <c>StriplightPRO.exe --smoke [outputDir]</c>: opens the demo roll, lets the page run its
/// self-test (select, frame preview), takes screenshots, exports every frame, writes
/// <c>smoke.json</c> and exits with 0 on success. Used by the Windows CI build.
/// </summary>
public sealed class SmokeTest(string outputDir)
{
    private readonly List<string> _log = [];
    private bool _failed;

    public string OutputDir { get; } = outputDir;

    public static SmokeTest? FromArgs(string[] args)
    {
        int i = Array.FindIndex(args, a => a.Equals("--smoke", StringComparison.OrdinalIgnoreCase));
        if (i < 0) return null;
        string dir = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[i + 1] : Path.Combine(Environment.CurrentDirectory, "smoke");
        Directory.CreateDirectory(dir);
        return new SmokeTest(Path.GetFullPath(dir));
    }

    private void Log(string s) => _log.Add($"{DateTime.Now:HH:mm:ss.fff} {s}");

    public void Fail(string why)
    {
        _failed = true;
        Log("FAIL " + why);
        Write(new { ok = false, log = _log });
    }

    public async Task RunAsync(Window window, CoreWebView2 core, AppController controller)
    {
        var result = new Dictionary<string, object?>();
        try
        {
            Log("page ready");
            await Task.Delay(3500); // let strip images load
            await Capture(core, "01-main");

            var selfTest = new TaskCompletionSource<JsonElement>();
            controller.OnSelfTestResult = r => selfTest.TrySetResult(r);
            await core.ExecuteScriptAsync("window.__striplightSelfTest && window.__striplightSelfTest()");
            var done = await Task.WhenAny(selfTest.Task, Task.Delay(30000));
            if (done != selfTest.Task) Fail("page self-test timed out");
            else
            {
                var r = selfTest.Task.Result;
                result["selfTest"] = r;
                Log("self-test " + r.GetRawText());
                if (!r.TryGetProperty("ok", out var ok) || !ok.GetBoolean()) Fail("page self-test reported a problem");
            }
            await Capture(core, "02-frame-preview");
            await core.ExecuteScriptAsync("window.__striplightSelfTestCleanup && window.__striplightSelfTestCleanup()");
            await Task.Delay(800);
            await Capture(core, "03-adjust-panel");

            var export = await controller.SmokeExportAsync(Path.Combine(OutputDir, "frames"));
            result["export"] = export;
            Log("export " + JsonSerializer.Serialize(export, BridgeHost.Json));
            if (export.Failed > 0 || export.Exported == 0) Fail("export failed");

            result["jsErrors"] = controller.JsErrors;
            if (controller.JsErrors.Count > 0) Fail("JavaScript errors: " + string.Join(" | ", controller.JsErrors));
        }
        catch (Exception e)
        {
            Fail(e.GetType().Name + ": " + e.Message);
        }

        result["ok"] = !_failed;
        result["log"] = _log;
        Write(result);
        window.Dispatcher.Invoke(() => Application.Current.Shutdown(_failed ? 1 : 0));
    }

    private void Write(object result) =>
        File.WriteAllText(Path.Combine(OutputDir, "smoke.json"),
            JsonSerializer.Serialize(result, new JsonSerializerOptions(BridgeHost.Json) { WriteIndented = true }));

    private async Task Capture(CoreWebView2 core, string name)
    {
        try
        {
            string png = Path.Combine(OutputDir, name + ".png");
            using (var fs = File.Create(png))
                await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);

            // Half-size JPEG as base64 too, so a screenshot can be read from the CI log alone.
            var frame = BitmapDecoder.Create(new Uri(png), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            var small = new TransformedBitmap(frame, new System.Windows.Media.ScaleTransform(0.5, 0.5));
            var enc = new JpegBitmapEncoder { QualityLevel = 60 };
            enc.Frames.Add(BitmapFrame.Create(small));
            using var ms = new MemoryStream();
            enc.Save(ms);
            File.WriteAllText(Path.Combine(OutputDir, name + ".jpg.b64"), Convert.ToBase64String(ms.ToArray()), Encoding.ASCII);
            Log("captured " + name);
        }
        catch (Exception e) { Log($"capture {name} failed: {e.Message}"); }
    }
}

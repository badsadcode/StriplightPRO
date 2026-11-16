using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;
using Striplight.App.Services;

namespace Striplight.App;

/// <summary>What the controller needs from the window layer.</summary>
public interface IWindowHost
{
    void OpenPreview(int index);
    void ClosePreview();
    void SetPreviewTopmost(bool value);
    void ApplyTheme(bool dark);
    void OpenHelp(string topic);
    PreviewWindow? Preview { get; }
}

/// <summary>
/// Hosts the main WebView2 page. Three channels connect pages to .NET:
///  * https://app.striplight/  — static files from wwwroot (virtual host mapping)
///  * https://img.striplight/  — strip and frame images rendered on demand by Striplight.Core
///  * chrome.webview.postMessage — JSON commands/replies/events (see Bridge/BridgeHost.cs)
/// The frame preview is a second window on the same bridge (PreviewWindow).
/// </summary>
public partial class MainWindow : Window, IWindowHost
{
    private readonly BridgeHost _bridge = new();
    private readonly AppController _controller;
    private readonly ImageService _images;
    private readonly SmokeTest? _smoke;
    private PreviewWindow? _preview;
    private HelpWindow? _help;
    private bool _closeConfirmed;

    public MainWindow()
    {
        InitializeComponent();
        _smoke = SmokeTest.FromArgs(Environment.GetCommandLineArgs());
        _controller = new AppController(this, _bridge, this) { SmokeMode = _smoke is not null };
        _images = new ImageService(_controller);
        SourceInitialized += (_, _) => DarkTitleBar.Apply(new WindowInteropHelper(this).Handle, _controller.Settings.Theme != "light");
        Loaded += async (_, _) => await InitWebViewAsync();
        Closing += OnClosing;
    }

    private async Task InitWebViewAsync()
    {
        try
        {
            var env = await WebViewSetup.EnvironmentAsync();
            await Web.EnsureCoreWebView2Async(env);
            Web.DefaultBackgroundColor = WebBackground(_controller.Settings.Theme != "light");
            WebViewSetup.Configure(Web.CoreWebView2, _bridge, _images, Dispatcher);

            if (_smoke is not null)
            {
                var core = Web.CoreWebView2;
                _bridge.On("app.ready", _ =>
                {
                    Dispatcher.InvokeAsync(() => _smoke.RunAsync(this, core, _controller, this));
                    return null;
                });
            }
            Web.Source = new Uri($"https://{WebViewSetup.AppHost}/index.html");
        }
        catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or COMException or InvalidOperationException)
        {
            if (_smoke is not null) { _smoke.Fail("WebView2 failed to start: " + ex.Message); Application.Current.Shutdown(2); return; }
            StartupError.Visibility = Visibility.Visible;
            StartupErrorText.Text =
                "The Microsoft Edge WebView2 Runtime is required. Install the Evergreen runtime from " +
                "https://developer.microsoft.com/microsoft-edge/webview2/ and start Striplight PRO again.\n\n" +
                ex.Message;
        }
    }

    private static System.Drawing.Color WebBackground(bool dark) => dark
        ? System.Drawing.Color.FromArgb(255, 0x0E, 0x0F, 0x12)
        : System.Drawing.Color.FromArgb(255, 0xF5, 0xF6, 0xF8);

    // ------------------------------------------------------------ IWindowHost

    public PreviewWindow? Preview => _preview;

    public void OpenPreview(int index)
    {
        if (_preview is not null)
        {
            _preview.ShowFrame(index);
            return;
        }
        _preview = new PreviewWindow(_bridge, _images, _controller.Settings, index);
        _preview.Closed += (_, _) =>
        {
            _preview = null;
            _bridge.Emit("preview.closed", null);
            Activate();
        };
        _preview.Show();
    }

    public void ClosePreview() => _preview?.Close();

    public void OpenHelp(string topic)
    {
        if (_help is not null) { _help.ShowTopic(topic); return; }
        _help = new HelpWindow(_bridge, _images, _controller.Settings, topic);
        _help.Closed += (_, _) => _help = null;
        _help.Show();
    }

    public void SetPreviewTopmost(bool value)
    {
        if (_preview is not null) _preview.Topmost = value;
    }

    public void ApplyTheme(bool dark)
    {
        DarkTitleBar.Apply(new WindowInteropHelper(this).Handle, dark);
        if (Web.CoreWebView2 is not null) Web.DefaultBackgroundColor = WebBackground(dark);
        _preview?.ApplyTheme(dark);
        _help?.ApplyTheme(dark);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_closeConfirmed || _smoke is not null) { _preview?.Close(); _help?.Close(); return; }
        if (!_controller.ConfirmDiscardOrSave("closing Striplight PRO"))
        {
            e.Cancel = true;
            return;
        }
        _preview?.Close();
        _help?.Close();
        _controller.Shutdown();
        _closeConfirmed = true;
    }
}

/// <summary>Native title bar coloured to match the app theme (Windows 10 20H1+ dark mode, Windows 11 caption colour).</summary>
internal static class DarkTitleBar
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWA_CAPTION_COLOR = 35;
    private const int DWMWA_TEXT_COLOR = 36;

    public static void Apply(IntPtr hwnd, bool dark)
    {
        if (hwnd == IntPtr.Zero) return;
        // Each call fails harmlessly on Windows versions that do not know the attribute.
        // Colours are COLORREF 0x00BBGGRR: dark #0E0F12 / light #F5F6F8, the app backgrounds.
        int mode = dark ? 1 : 0, round = 2;
        int caption = dark ? 0x00120F0E : 0x00F8F6F5;
        int border = dark ? 0x00221E1C : 0x00E2DED9;
        int text = dark ? 0x00ECE8E6 : 0x001D1815;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref mode, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, ref text, sizeof(int));
    }
}

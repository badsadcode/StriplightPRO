using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;
using Striplight.App.Services;

namespace Striplight.App;

/// <summary>
/// Hosts the WebView2 front end. Three channels connect it to .NET:
///  * https://app.striplight/  — static files from wwwroot (virtual host mapping)
///  * https://img.striplight/  — strip and frame images rendered on demand by Striplight.Core
///  * chrome.webview.postMessage — JSON commands/replies/events (see Bridge/BridgeHost.cs)
/// </summary>
public partial class MainWindow : Window
{
    public const string AppHost = "app.striplight";
    public const string ImageHost = "img.striplight";

    private readonly BridgeHost _bridge = new();
    private readonly AppController _controller;
    private readonly ImageService _images;
    private readonly SmokeTest? _smoke;
    private bool _closeConfirmed;

    public MainWindow()
    {
        InitializeComponent();
        _smoke = SmokeTest.FromArgs(Environment.GetCommandLineArgs());
        _controller = new AppController(this, _bridge) { SmokeMode = _smoke is not null };
        _images = new ImageService(_controller);
        SourceInitialized += (_, _) => DarkTitleBar.Apply(new WindowInteropHelper(this).Handle);
        Loaded += async (_, _) => await InitWebViewAsync();
        Closing += OnClosing;
    }

    private async Task InitWebViewAsync()
    {
        try
        {
            string userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StriplightPRO", "WebView2");
            var env = await CoreWebView2Environment.CreateAsync(null, userData);
            await Web.EnsureCoreWebView2Async(env);
            Web.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 0x0E, 0x0F, 0x12);

            var core = Web.CoreWebView2;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false; // F5/Ctrl+R would reload and drop state
#if DEBUG
            core.Settings.AreDevToolsEnabled = true;
#else
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
#endif
            string wwwroot = Path.Combine(AppContext.BaseDirectory, "wwwroot");
            core.SetVirtualHostNameToFolderMapping(AppHost, wwwroot, CoreWebView2HostResourceAccessKind.Deny);

            core.AddWebResourceRequestedFilter($"https://{ImageHost}/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (s, e) => _images.Handle(core.Environment, e);

            core.WebMessageReceived += async (_, e) =>
            {
                string reply = await _bridge.HandleAsync(e.WebMessageAsJson);
                core.PostWebMessageAsJson(reply);
            };
            _bridge.Outgoing += json => Dispatcher.Invoke(() => core.PostWebMessageAsJson(json));

            // Keep navigation inside the app; open anything else in the default browser.
            core.NewWindowRequested += (_, e) => { e.Handled = true; Shell.OpenUrl(e.Uri); };
            core.NavigationStarting += (_, e) =>
            {
                if (!e.Uri.StartsWith($"https://{AppHost}/", StringComparison.OrdinalIgnoreCase))
                {
                    e.Cancel = true;
                    Shell.OpenUrl(e.Uri);
                }
            };

            if (_smoke is not null)
            {
                _bridge.On("app.ready", _ =>
                {
                    Dispatcher.InvokeAsync(() => _smoke.RunAsync(this, core, _controller));
                    return null;
                });
            }

            Web.Source = new Uri($"https://{AppHost}/index.html");
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

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_closeConfirmed || _smoke is not null) return;
        if (!_controller.ConfirmDiscardOrSave("closing Striplight PRO"))
        {
            e.Cancel = true;
            return;
        }
        _controller.Shutdown();
        _closeConfirmed = true;
    }
}

/// <summary>Dark, app-coloured native title bar (Windows 10 20H1+ dark mode, Windows 11 caption colour).</summary>
internal static class DarkTitleBar
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWA_CAPTION_COLOR = 35;
    private const int DWMWA_TEXT_COLOR = 36;

    public static void Apply(IntPtr hwnd)
    {
        // Each call fails harmlessly on Windows versions that do not know the attribute.
        int on = 1, round = 2;
        int caption = 0x00120F0E; // COLORREF 0x00BBGGRR = #0E0F12, the app background
        int border = 0x00221E1C;
        int text = 0x00E6E8EC;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, ref text, sizeof(int));
    }
}

using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
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
    private bool _closeConfirmed;

    public MainWindow()
    {
        InitializeComponent();
        _controller = new AppController(this, _bridge);
        _images = new ImageService(_controller);
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
            Web.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 0x15, 0x17, 0x1A);

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

            Web.Source = new Uri($"https://{AppHost}/index.html");
        }
        catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or COMException or InvalidOperationException)
        {
            StartupError.Visibility = Visibility.Visible;
            StartupErrorText.Text =
                "The Microsoft Edge WebView2 Runtime is required. Install the Evergreen runtime from " +
                "https://developer.microsoft.com/microsoft-edge/webview2/ and start Striplight PRO again.\n\n" +
                ex.Message;
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_closeConfirmed) return;
        if (!_controller.ConfirmDiscardOrSave("closing Striplight PRO"))
        {
            e.Cancel = true;
            return;
        }
        _controller.Shutdown();
        _closeConfirmed = true;
    }
}

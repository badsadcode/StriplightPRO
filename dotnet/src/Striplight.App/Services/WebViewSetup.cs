using System.IO;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;

namespace Striplight.App.Services;

/// <summary>
/// Shared WebView2 setup for the main window and the preview window: one browser
/// environment, the app/image virtual hosts and the JSON bridge. Both pages talk to the
/// same <see cref="BridgeHost"/>; replies go to the page that asked, events go to every page.
/// </summary>
public static class WebViewSetup
{
    public const string AppHost = "app.striplight";
    public const string ImageHost = "img.striplight";

    private static Task<CoreWebView2Environment>? _env;

    public static Task<CoreWebView2Environment> EnvironmentAsync()
    {
        string userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StriplightPRO", "WebView2");
        return _env ??= CoreWebView2Environment.CreateAsync(null, userData);
    }

    /// <summary>Configures a freshly initialised WebView2. Returns an action that detaches it from the bridge.</summary>
    public static Action Configure(CoreWebView2 core, BridgeHost bridge, ImageService images, Dispatcher dispatcher)
    {
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
        core.WebResourceRequested += (_, e) => images.Handle(core.Environment, e);

        core.WebMessageReceived += async (_, e) =>
        {
            string reply = await bridge.HandleAsync(e.WebMessageAsJson);
            core.PostWebMessageAsJson(reply);
        };
        void Post(string json) => dispatcher.Invoke(() => core.PostWebMessageAsJson(json));
        bridge.Outgoing += Post;

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
        return () => bridge.Outgoing -= Post;
    }
}

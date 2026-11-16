using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;
using Striplight.App.Services;

namespace Striplight.App;

/// <summary>
/// Separate, resizable frame preview (like the Lazarus "Frame Preview" form): its own
/// WebView2 page (wwwroot/preview.html) on the same bridge as the main window, with an
/// "always on top" option. The window remembers its position and size.
/// </summary>
public partial class PreviewWindow : Window
{
    private readonly BridgeHost _bridge;
    private readonly ImageService _images;
    private readonly AppSettings _settings;
    private Action? _detach;
    private int _pendingIndex;

    public CoreWebView2? Core => Web.CoreWebView2;

    public PreviewWindow(BridgeHost bridge, ImageService images, AppSettings settings, int index)
    {
        InitializeComponent();
        _bridge = bridge;
        _images = images;
        _settings = settings;
        _pendingIndex = index;

        Width = Math.Max(MinWidth, settings.PreviewWidth);
        Height = Math.Max(MinHeight, settings.PreviewHeight);
        if (settings.PreviewLeft is double l && settings.PreviewTop is double t && OnScreen(l, t))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = l;
            Top = t;
        }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = settings.PreviewTopmost;

        SourceInitialized += (_, _) => DarkTitleBar.Apply(new WindowInteropHelper(this).Handle, settings.Theme != "light");
        Loaded += async (_, _) => await InitAsync();
        Closed += (_, _) =>
        {
            _detach?.Invoke();
            _settings.PreviewLeft = Left;
            _settings.PreviewTop = Top;
            _settings.PreviewWidth = Width;
            _settings.PreviewHeight = Height;
        };
    }

    private static bool OnScreen(double left, double top) =>
        left > SystemParameters.VirtualScreenLeft - 50 && top > SystemParameters.VirtualScreenTop - 50 &&
        left < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100 &&
        top < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 100;

    private async Task InitAsync()
    {
        try
        {
            var env = await WebViewSetup.EnvironmentAsync();
            await Web.EnsureCoreWebView2Async(env);
            Web.DefaultBackgroundColor = _settings.Theme == "light"
                ? System.Drawing.Color.FromArgb(255, 0xF5, 0xF6, 0xF8)
                : System.Drawing.Color.FromArgb(255, 0x0E, 0x0F, 0x12);
            _detach = WebViewSetup.Configure(Web.CoreWebView2, _bridge, _images, Dispatcher);
            Web.Source = new Uri($"https://{WebViewSetup.AppHost}/preview.html?i={_pendingIndex}");
        }
        catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or System.Runtime.InteropServices.COMException)
        {
            MessageBox.Show(this, "The frame preview could not start: " + ex.Message, "Striplight PRO");
            Close();
        }
    }

    /// <summary>Shows another frame in an already open preview.</summary>
    public void ShowFrame(int index)
    {
        _pendingIndex = index;
        _bridge.Emit("preview.show", new { index });
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    public void ApplyTheme(bool dark)
    {
        DarkTitleBar.Apply(new WindowInteropHelper(this).Handle, dark);
        if (Web.CoreWebView2 is not null)
            Web.DefaultBackgroundColor = dark
                ? System.Drawing.Color.FromArgb(255, 0x0E, 0x0F, 0x12)
                : System.Drawing.Color.FromArgb(255, 0xF5, 0xF6, 0xF8);
    }
}

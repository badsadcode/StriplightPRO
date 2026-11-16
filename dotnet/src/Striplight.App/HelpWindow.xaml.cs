using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;
using Striplight.App.Bridge;
using Striplight.App.Services;

namespace Striplight.App;

/// <summary>
/// The manual (wwwroot/help.html + help/{lang}.html) in its own window, so it can stay
/// open beside the work. Same bridge as the other windows (language, theme).
/// </summary>
public partial class HelpWindow : Window
{
    private readonly BridgeHost _bridge;
    private readonly ImageService _images;
    private readonly AppSettings _settings;
    private readonly string _topic;
    private Action? _detach;

    public HelpWindow(BridgeHost bridge, ImageService images, AppSettings settings, string topic)
    {
        InitializeComponent();
        _bridge = bridge;
        _images = images;
        _settings = settings;
        _topic = topic;
        Title = Loc.T("Striplight PRO — Help");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => DarkTitleBar.Apply(new WindowInteropHelper(this).Handle, settings.Theme != "light");
        Loaded += async (_, _) => await InitAsync();
        Closed += (_, _) => _detach?.Invoke();
    }

    private async Task InitAsync()
    {
        try
        {
            var env = await WebViewSetup.EnvironmentAsync();
            await Web.EnsureCoreWebView2Async(env);
            ApplyTheme(_settings.Theme != "light");
            _detach = WebViewSetup.Configure(Web.CoreWebView2, _bridge, _images, Dispatcher);
            Web.Source = new Uri($"https://{WebViewSetup.AppHost}/help.html#{Uri.EscapeDataString(_topic)}");
        }
        catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or System.Runtime.InteropServices.COMException)
        {
            MessageBox.Show(this, ex.Message, "Striplight PRO");
            Close();
        }
    }

    /// <summary>Shows a topic in the already open manual.</summary>
    public void ShowTopic(string topic)
    {
        _bridge.Emit("help.show", new { topic });
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

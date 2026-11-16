using System.Windows;
using System.Windows.Threading;

namespace Striplight.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);
    }

    private static void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // Keep the app alive on unexpected UI-thread errors; unsaved work matters more than a clean crash.
        MessageBox.Show(e.Exception.Message, Services.Loc.T("Striplight PRO — unexpected error"),
            MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}

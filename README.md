# Striplight PRO

Windows desktop tools for reviewing scanned microfilm strips, detecting and adjusting frame boundaries, and exporting frame images.

This repository holds two editions side by side. They read and write the same roll files (`.idf`, `.qpf`, `.slf`).

| Folder | Edition | Stack | Status |
|---|---|---|---|
| [`dotnet/`](dotnet/README.md) | **Striplight PRO** (new) | C# / .NET 10, WPF + Microsoft Edge WebView2, HTML5 / CSS3 / vanilla JS, TOAST UI Editor (ProseMirror) | In progress: core engine, strip view, detection, tone, export and roll notes work; see the feature table |
| [`lazarus/`](lazarus/README.md) | Striplight 48.5 (original) | Lazarus 2.2.4 / Free Pascal 3.2.2, BGRABitmap | Complete. Kept as-is and built separately |

`assets/` holds the icons and artwork shared by both editions.

## Quick start (C# edition)

Needs Windows 10/11 x64, the [.NET 10 SDK](https://dotnet.microsoft.com/download) and the Evergreen [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) (already present on current Windows 11).

```powershell
cd dotnet
dotnet test                                   # engine tests
dotnet run --project src/Striplight.App       # start the app
```

More, including publishing, is in [`dotnet/README.md`](dotnet/README.md). To build the Lazarus edition, see [`lazarus/README.md`](lazarus/README.md).

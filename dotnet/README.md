# Striplight PRO — C# / WPF / WebView2 edition

A rewrite of the Lazarus Striplight (`../lazarus/`) as a .NET 10 desktop app. The window is WPF; everything you see inside it is an HTML5/CSS3/vanilla-JavaScript page in Microsoft Edge WebView2. All imaging and file work runs in a plain .NET library that has no UI code and is unit tested.

- **Language:** C# (.NET 10), JavaScript (ES modules, no framework)
- **Framework:** WPF + Microsoft Edge WebView2
- **Front end:** HTML5, CSS3, vanilla JS, canvas strip view
- **Editor:** TOAST UI Editor 3.2.2, built on ProseMirror, for the roll notes
- **Imaging:** libjpeg-turbo (TurboJPEG API), bundled for Windows x64
- **Platform:** Windows 10/11 x64

## Build and run

Requirements: the .NET 10 SDK (`global.json` accepts 10.0.100 or newer feature bands) and the Evergreen WebView2 Runtime.

```powershell
cd dotnet
dotnet build
dotnet test
dotnet run --project src/Striplight.App
```

Publish a folder build that depends on the installed .NET 10 desktop runtime (about 5 MB):

```powershell
dotnet publish src/Striplight.App -c Release -r win-x64 --self-contained false -o publish
```

Add `--self-contained true` to include the .NET runtime, so the target PC needs no .NET install (the folder is then well over 100 MB). The WebView2 runtime is not bundled: it is preinstalled on Windows 11 and on up-to-date Windows 10.

Visual Studio 2026 opens `StriplightPro.slnx` directly; any editor works with the .NET 10 SDK command line.

> The WPF project also *builds* on Linux and macOS (`EnableWindowsTargeting`), so CI can compile it. It only *runs* on Windows. The engine tests run anywhere; on Linux install `libturbojpeg` to include the JPEG end-to-end tests.

## Layout

```
dotnet/
  StriplightPro.slnx
  Directory.Build.props        shared settings (nullable, C# latest, version)
  native/win-x64/              libturbojpeg.dll (libjpeg-turbo 3.2.0) + licenses in native/third-party/
  src/Striplight.Core/         engine: no WPF, no WebView2
    Model/                     RollData, FrameRecord, FrameList (stats), RollPaths
    IO/                        IdfParser, ProjectFile (QPF/SLF + notes)
    Imaging/                   ToneAdjust, GrayImage, TurboJpeg, GrayStripCache
    Detection/                 FrameDetector (preview-based)
    Export/                    ExportNaming, FrameBuilder, ExportEngine (parallel)
    Editing/                   FrameEditor (delete, markers, add, overrides)
    Preview/                   StripPreviewRenderer (strip view + frame preview images)
  src/Striplight.App/          WPF shell
    MainWindow.xaml(.cs)       WebView2 setup: virtual hosts, image requests, messages
    Bridge/BridgeHost.cs       JSON command/reply/event bridge
    Services/AppController.cs  open/save, frame edits, detection, export commands
    Services/ImageService.cs   serves https://img.striplight/strip|frame/{n}
    Services/AppSettings.cs    per-user preferences (%APPDATA%\StriplightPRO\settings.json)
    wwwroot/                   the UI: index.html, css/app.css, js/*.js, vendor/toastui/
    web-vendor/                how the TOAST UI bundle is built (npm + esbuild); not shipped
  tests/Striplight.Core.Tests/ xUnit tests
```

## How the pieces talk

```
 WebView2 page (wwwroot)                         .NET (Striplight.App → Striplight.Core)
 ─────────────────────────                       ──────────────────────────────────────
 https://app.striplight/index.html  ◄── files ── SetVirtualHostNameToFolderMapping(wwwroot)
 <img src="https://img.striplight/strip/12?v=7"> ── WebResourceRequested ──► ImageService
                                                     preview JPEG → tone → upright → JPEG
 bridge.call('frames.patch', {...})  ── postMessage JSON ──► BridgeHost → AppController
 bridge.on('export.progress', ...)   ◄── PostWebMessageAsJson ── events from workers
```

- The **host owns the project.** The page keeps a copy of the frame list for drawing; every edit (drag, resize, new frame, marker, delete) goes to the host, which sorts, re-flags odd sizes and sends the list back.
- **Images carry a version** (`?v=`). Changing tone or orientation bumps it, so the page never shows a stale strip.
- **Preview = export.** The frame preview window is rendered by the same `FrameBuilder` the export uses.
- Bridge commands are listed in `AppController.Register()`; the page side is `wwwroot/js/bridge.js`.

## File compatibility

- `.idf` (QuantumScan roll) is read. Opening an `.idf` that has a `.slf` next to it opens the `.slf`, because that holds your edits.
- `.slf` is read and written. This edition adds one element, `<StriplightNotes Format="markdown">`, holding the roll notes as CDATA. The Lazarus edition ignores unknown elements, so SLF files stay usable in both editions.
- `.qpf` is read and can be written with **Save as… → QuantumScan project**. QPF never contains notes or Striplight-only frame fields.
- Tone method numbers, flags and per-frame fields match the Lazarus edition, so a roll tuned in one looks the same in the other.

## What is ported

| Area | Lazarus feature | C# edition |
|---|---|---|
| Files | IDF, QPF, SLF load/save, legacy INI SLF | ✅ (+ roll notes in SLF) |
| Strip view | Paged rows, zoom, strips per row, CW/CCW source orientation | ✅ canvas, Ctrl+wheel zoom |
| | Frame overlays (normal / odd size / marker / suggested / selected / exported / per-frame) | ✅ |
| | Select, Ctrl/Shift select, move, resize edges, draw new frame | ✅ |
| | Trim lines, detection range/area drag handles, split preview, stacked-frame click cycling | ⏳ TODO |
| Frames | Delete, toggle/clear markers, per-frame rotate/mirror/negative, clear overrides | ✅ |
| | Suggest markers, combine overlapping, merge adjacent, close gaps, expand, split, select by size | ⏳ TODO |
| Detection | Preview-based detection with threshold, min size, strip range, insets | ✅ |
| Tone | All 9 methods (classic LUTs + auto levels, CLAHE, exposure balance, background flatten), 5 flags, sharpen | ✅ same math, tested |
| | Per-frame tone sliders | ⏳ values are honoured on export, but not editable yet |
| Export | Quantum folder naming, archive-list naming, digits/prefix, skip existing, preview fallback, local temp staging | ✅ |
| | Parallel workers, shared strip cache, pause/stop, failure list | ✅ |
| | Grayscale TurboJPEG output | ✅ |
| | Colour output, built-in (FPWriteJPEG) encoder | ⏳ TODO: frames are built in 8-bit gray. Colour strips are converted to gray |
| Cache | Local preview cache, standalone cache manager | ⏳ TODO (RollPaths already supports the cache path) |
| Notes | — | ✅ new: TOAST UI Markdown / WYSIWYG roll notes |

Behaviour notes:

- Adaptive tone methods run **per strip** in the strip view and **per frame** in the frame preview and export, as in the Lazarus edition. Use *Preview frame* (Enter) to see the exact result.
- Detection uses the Process brightness/contrast/gamma sliders when the method uses Striplight ranges, as before. Quantum-range methods detect on the untouched preview.

## Keyboard

| Key | Action |
|---|---|
| Ctrl+O / Ctrl+S / Ctrl+Shift+S | Open, Save, Save as |
| Page Up / Page Down / Home / End | Pages |
| Ctrl+wheel, + / − | Zoom |
| Click, Ctrl+click, Shift+click, Ctrl+A, Esc | Selection |
| M | Toggle folder marker |
| Delete | Delete selected frames |
| Enter / double-click | Frame preview (← → to step, M marker, Esc close) |
| Esc while dragging | Cancel the drag |

## Updating the editor bundle

`wwwroot/vendor/toastui/toastui-editor.bundle.js` is committed so building the app never needs Node. To update it:

```powershell
cd src/Striplight.App/web-vendor
npm install
npm run build
```

`build.mjs` bundles `@toast-ui/editor` together with its ProseMirror packages into one offline file and copies the CSS and licence files. The editor is created with `usageStatistics: false`, so it makes no network calls.

## Third-party

- libjpeg-turbo 3.2.0 (`native/win-x64/libturbojpeg.dll`). IJG / BSD-style licences in `native/third-party/`.
- TOAST UI Editor 3.2.2 (MIT) and ProseMirror (MIT). See `wwwroot/vendor/toastui/THIRD-PARTY-NOTICES.md`.
- Microsoft.Web.WebView2 (NuGet).

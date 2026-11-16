# Striplight PRO — C# / WPF / WebView2 edition

A rewrite of the Lazarus Striplight (`../lazarus/`) as a .NET 10 desktop app. The window is WPF; everything you see inside it is an HTML5/CSS3/vanilla-JavaScript page in Microsoft Edge WebView2. All imaging and file work runs in a plain .NET library that has no UI code and is unit tested.

- **Language:** C# (.NET 10), JavaScript (ES modules, no framework)
- **Framework:** WPF + Microsoft Edge WebView2
- **Front end:** HTML5, CSS3, vanilla JS, canvas strip view
- **Editor:** TOAST UI Editor 3.2.2, built on ProseMirror, for the roll notes
- **Imaging:** libjpeg-turbo (TurboJPEG API), bundled for Windows x64
- **Platform:** Windows 10/11 x64

## Get an exe to test

Every push that touches `dotnet/` runs the **Windows build** workflow (`.github/workflows/windows-build.yml`). Open the run on GitHub (Actions tab → Windows build) and download from **Artifacts**:

- `StriplightPRO-win-x64-single-exe`: one `StriplightPRO.exe`, about 65 MB, with .NET included. Nothing to install apart from the WebView2 runtime, which Windows 11 already has.
- `StriplightPRO-win-x64-folder`: a small folder build that needs the [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0).
- `smoke-test-results`: screenshots and `smoke.json` from the automatic test run.

No scans at hand? Click **Try the demo roll** on the welcome screen. Striplight generates a small synthetic roll in `%LOCALAPPDATA%\StriplightPRO\Demo`.

The workflow also runs `StriplightPRO.exe --smoke <folder>`. It opens the demo roll, lets the page check itself (strip images, notes editor, frame preview), takes screenshots, exports every frame and exits with 0 on success.

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
    Demo/                      DemoRoll: synthetic roll for trying the app
  src/Striplight.App/          WPF shell
    MainWindow.xaml(.cs)       WebView2 setup: virtual hosts, image requests, messages
    Bridge/BridgeHost.cs       JSON command/reply/event bridge
    Services/AppController.cs  open/save, frame edits, detection, export commands
    Services/ImageService.cs   serves https://img.striplight/strip|frame/{n}
    Services/AppSettings.cs    per-user preferences (%APPDATA%\StriplightPRO\settings.json)
    Services/SmokeTest.cs      --smoke self-test used by CI
    wwwroot/                   the UI: index.html, css/app.css, js/*.js, vendor/toastui/
      js/app.js                page controller (panels, commands, keyboard)
      js/stripView.js          canvas strip view (layout, overlays, editing)
      js/scrubber.js           roll overview under the strip view
      js/ui.js, js/icons.js    custom controls, Lucide icons (generated)
    web-vendor/                how the TOAST UI bundle and icons are built (npm); not shipped
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
| Strip view | Paged rows, zoom, strips per row (+ Auto), CW/CCW source orientation | ✅ canvas, Ctrl+wheel zoom, optional strip numbers |
| | Frame overlays (normal / odd size / marker / suggested / selected / exported / per-frame) | ✅ |
| | Select, Ctrl/Shift select, move, resize edges, draw new frame | ✅ |
| | Trim lines, detection range/area drag handles, split preview, stacked-frame click cycling | ⏳ TODO |
| Frames | Delete, toggle/clear markers, per-frame rotate/mirror/negative, clear overrides | ✅ |
| | Merge pairs (E), combine overlapping (J), split (S), toggle suggested (Z), undo (Ctrl+Z) | ✅ |
| | Suggest markers (gap-based, strictness, before/after gap, toward start/end), select / clear / every Nth / make markers, clear markers toward start/end | ✅ |
| | Close gaps, expand, select by size | ⏳ TODO |
| Preview | Separate window, always on top, wheel zoom, pan, fit / 1:1, full quality, frame step, markers, per-frame rotate/mirror/negative | ✅ |
| Detection | Preview-based detection with threshold, min size, strip range, insets | ✅ uses the on-screen tone curve; live view that follows the scan |
| Tone | All 9 methods (classic LUTs + auto levels, CLAHE, exposure balance, background flatten), 5 flags, sharpen | ✅ same math, tested |
| | Per-frame tone sliders | ⏳ values are honoured on export, but not editable yet |
| Export | Quantum folder naming, archive-list naming, digits/prefix, skip existing, preview fallback, local temp staging | ✅ |
| | Parallel workers, shared strip cache, pause/stop, failure list, prepare folders | ✅ |
| | Grayscale TurboJPEG output | ✅ |
| | Colour output, built-in (FPWriteJPEG) encoder | ⏳ TODO: frames are built in 8-bit gray. Colour strips are converted to gray |
| Cache | Local preview cache, standalone cache manager | ⏳ TODO (RollPaths already supports the cache path) |
| Notes | — | ✅ new: TOAST UI Markdown / WYSIWYG roll notes |
| Themes | — | ✅ new: light / dark, remembered |

Behaviour notes:

- Adaptive tone methods run **per strip** in the strip view and **per frame** in the frame preview and export, as in the Lazarus edition. Use *Preview frame* (Enter) to see the exact result.
- Detection uses the Process brightness/contrast/gamma sliders when the method uses Striplight ranges, as before. Quantum-range methods detect on the untouched preview.

## Keyboard

All shortcuts are configurable: press `?` (or the keyboard button) to open the shortcut editor, click + to add a key, × to remove one. Commands without a default key (fill gaps, join close, expand, trim, select section, detect, suggest...) can be bound too. Bindings are saved in `settings.json` and apply to the main and preview windows.

Defaults (same keys as the Lazarus edition):

| Key | Action |
|---|---|
| Ctrl+O / Ctrl+S / Ctrl+Shift+S | Open, Save, Save as |
| X / C, Page Up / Page Down, Home / End | Previous / next page, first / last page |
| G / F | Previous / next folder marker |
| Ctrl+wheel, + / − | Zoom (wheel alone turns pages) |
| Click, Ctrl+click, Shift+click | Select, add, range |
| Ctrl+A / Ctrl+D or Esc | Select all / none |
| A (or M) | Toggle folder marker |
| D / Delete | Delete selected frames (Delete asks first for more than 20) |
| E / J / S | Merge pairs / combine overlapping / split into N parts |
| Z | Toggle suggested marker (one frame) |
| Ctrl+Z | Undo frame change (25 steps) |
| Enter / double-click | Open the preview window |
| Esc while dragging | Cancel the drag |
| Right-click | Context menu (Lazarus-style: marker, merge, split, fill gaps, join close, expand, select / delete section, detection start / end here) |

Preview window: X / C (or ← / →) previous / next frame by the step, G / F folder markers, R / Shift+R rotate ±90°, M mirror, N negative, A marker, wheel zoom around the cursor, drag to pan, double-click or 0 / 1 for fit / 1:1, Q full quality, T always on top, I show / hide the target banner (folder number, target folder, file name), Esc close.

## Help

**Help** (the ? circle in the app bar, or **F1**) opens the manual in its own window, at the topic of the panel in front. It is written in English and Polish (`wwwroot/help/en.html`, `help/pl.html`; one `<section id>` per topic with an `<h2>`), has a contents list and search, and follows the chosen language and theme. Keep both files in step when features change.

## Real-world speed

Same roll (4,860 strips, 3,435 frames, quality 94), exported over the network to a share in another building:

| | Workers | Time | Frames/s |
|---|---|---|---|
| Lazarus edition | 16 | ~26 min | ~2.2 |
| Striplight PRO | 10 | 10.7 min | 5.3 |
| Striplight PRO | 16 | 10.5 min | 5.4 |

PRO is about 2.5× faster with the same workers. Going from 10 to 16 workers gained ~1.5% because the share was already the limit: more workers only help while the network has room. Workers are not capped; choose what suits the PC.

## Languages

English (default) and Polish. Switch with the **EN / PL** button in the app bar; both windows reload in the new language and the open roll stays as it is.

- The English text is the key: `wwwroot/i18n/pl.json` maps it to Polish. Anything missing stays English. Counts use plural objects (`{ "one", "few", "many", "other" }`, chosen with `Intl.PluralRules`), e.g. 1 klatka / 2 klatki / 5 klatek.
- Your own corrections: *Language → Edit translations* copies `pl.json` to `%APPDATA%\StriplightPRO\lang\` and opens the folder. Entries there override the built-in file and survive updates (switch the language again to reload).
- Page side: `wwwroot/js/i18n.js` (`t()`, `tn()`, start-up translation of the static HTML). Host side: `Services/Loc.cs` (`Loc.T()` for dialogs and error messages); both use the same dictionary.
- After changing UI text run `python dotnet/tools/i18n_check.py`: it lists strings missing from (or no longer used in) `pl.json`.
- Terms used in Polish: frame = *klatka*, marker = *znacznik*, strip = *pasek*, roll = *rolka*.

## Interface

The window has a dark native title bar, an app bar (roll name, Open / Save as / Save, shortcuts), a tool rail on the left (Frames, Detect, Adjust, Export, Notes), the strip view in the middle and an inspector on the right showing the panel for the selected tool. Over the strip view sit a floating toolbar (pages, zoom, strips per row, CW orientation) and, at the bottom, the legend and a roll scrubber. The scrubber marks folder markers, odd-size frames, the selection and exported frames along the whole roll, highlights the visible page, and jumps when you click or drag.

## Updating the editor bundle

`wwwroot/vendor/toastui/toastui-editor.bundle.js` is committed so building the app never needs Node. To update it:

```powershell
cd src/Striplight.App/web-vendor
npm install
npm run build
```

This rebuilds the editor bundle and `wwwroot/js/icons.js` (from `lucide-static`, ISC licence; the icon list is in `build-icons.mjs`). `build.mjs` bundles `@toast-ui/editor` together with its ProseMirror packages into one offline file and copies the CSS and licence files. The editor is created with `usageStatistics: false`, so it makes no network calls.

## Third-party

- libjpeg-turbo 3.2.0 (`native/win-x64/libturbojpeg.dll`). IJG / BSD-style licences in `native/third-party/`.
- TOAST UI Editor 3.2.2 (MIT) and ProseMirror (MIT). See `wwwroot/vendor/toastui/THIRD-PARTY-NOTICES.md`.
- Lucide icons 0.544.0 (ISC). See `wwwroot/js/LICENSE-lucide.txt`.
- Microsoft.Web.WebView2 (NuGet).

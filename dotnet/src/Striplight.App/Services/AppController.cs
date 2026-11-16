using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using Microsoft.Win32;
using Striplight.App.Bridge;
using Striplight.Core.Demo;
using Striplight.Core.Detection;
using Striplight.Core.Editing;
using Striplight.Core.Export;
using Striplight.Core.Imaging;
using Striplight.Core.IO;
using Striplight.Core.Model;

namespace Striplight.App.Services;

/// <summary>
/// Owns the open project and implements every bridge command. All methods run on the
/// UI thread; long work (detection, export) runs on the thread pool with private copies.
/// </summary>
public sealed class AppController
{
    private const int UndoSteps = 25; // as in the Lazarus edition

    private readonly Window _owner;
    private readonly BridgeHost _bridge;
    private readonly IWindowHost _host;
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly List<List<FrameRecord>> _undo = [];

    private Project _project = new();
    private string _projectPath = "";
    private string _idfPath = "";
    private bool _dirty;
    private ProcessDto _process = new();
    private ExportDto _export = new();
    private int _imageVersion = 1;

    private CancellationTokenSource? _detectCts;
    private CancellationTokenSource? _exportCts;
    private ExportEngine? _exportEngine;

    public AppController(Window owner, BridgeHost bridge, IWindowHost host)
    {
        _owner = owner;
        _bridge = bridge;
        _host = host;
        Register();
    }

    public AppSettings Settings => _settings;

    // ------------------------------------------------------------ smoke test hooks

    public bool SmokeMode { get; init; }
    public List<string> JsErrors { get; } = [];
    public Action<JsonElement>? OnSelfTestResult { get; set; }

    private static string DemoFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StriplightPRO", "Demo");

    public async Task<ExportSummary> SmokeExportAsync(string outputRoot)
    {
        var naming = new NamingOptions { OutputRoot = outputRoot, FileDigits = 5, SeparateFolders = true };
        var jobs = ExportEngine.BuildJobs(_project.Frames, Enumerable.Range(0, _project.Frames.Count), naming);
        return await new ExportEngine().RunAsync(_project.Roll, _project.Frames, jobs,
            _process.ToProcessSettings(_settings.RotateCw), new ExportOptions { Workers = 4 });
    }

    // ------------------------------------------------------------ state for ImageService

    public RollData Roll => _project.Roll;
    public bool RotateCw => _settings.RotateCw;
    public ProcessDto Process => _process;
    public int FrameCount => _project.Frames.Count;
    /// <summary>Frames with their own tone that touch a strip, with the tone each one uses.</summary>
    public List<(FrameRecord Frame, ToneSettings Tone)> FrameTonesOnStrip(int strip)
    {
        var result = new List<(FrameRecord, ToneSettings)>();
        int ll = _project.Roll.LengthLines;
        if (ll <= 0) return result;
        var ps = _process.ToProcessSettings(_settings.RotateCw);
        foreach (var f in _project.Frames)
        {
            if (!f.HasToneOverride || f.LeadStrip(ll) > strip || (f.TrailEdge - 1) / ll < strip) continue;
            result.Add((f.Clone(), FrameBuilder.Resolve(f, ps).Tone));
        }
        return result;
    }

    public FrameRecord? SnapshotFrame(int index) =>
        index >= 0 && index < _project.Frames.Count ? _project.Frames[index].Clone() : null;

    // ------------------------------------------------------------ commands

    private void Register()
    {
        _bridge.On("app.log", args =>
        {
            string msg = BridgeHost.Arg(args, "message", "");
            if (msg != "") lock (JsErrors) JsErrors.Add(msg);
            return null;
        });
        _bridge.On("smoke.result", args => { OnSelfTestResult?.Invoke(args.Clone()); return null; });
        _bridge.OnAsync("project.demo", async _ =>
        {
            if (!ConfirmDiscardOrSave("opening the demo roll")) return null;
            string idf = await Task.Run(() => DemoRoll.Create(DemoFolder));
            _dirty = false;
            return OpenProject(idf);
        });
        _bridge.On("app.init", _ => new
        {
            version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.1.0",
            turboJpeg = TurboJpeg.Status,
            toneMethods = Enumerable.Range(0, ToneMethod.Count).Select(ToneAdjust.MethodName).ToArray(),
            settings = _settings,
            session = SmokeMode ? OpenProject(DemoRoll.Create(DemoFolder)) : _project.Roll.Loaded ? Session() : null,
            smoke = SmokeMode,
        });

        _bridge.On("project.open", args => OpenProject(BridgeHost.Arg(args, "path", "")));
        _bridge.On("project.save", _ => Save(saveAs: false));
        _bridge.On("project.saveAs", _ => Save(saveAs: true));
        _bridge.On("project.close", _ => CloseProject());

        _bridge.On("frames.patch", args =>
        {
            PushUndo();
            foreach (var p in BridgeHost.Arg(args, "changes", new List<FramePatch>()))
                if (p.Index >= 0 && p.Index < _project.Frames.Count && p.Frame.IsPersistable)
                    CopyEditable(p.Frame, _project.Frames[p.Index]);
            FrameEditor.Refresh(_project.Frames); // a drag can change the order
            return Changed(args);
        });
        _bridge.On("frames.add", args =>
        {
            var f = BridgeHost.Arg(args, "frame", new FrameRecord());
            PushUndo();
            int idx = FrameEditor.Add(_project.Frames, f);
            Changed(args);
            return new { frames = _project.Frames, index = idx };
        });
        _bridge.On("frames.delete", args =>
        {
            PushUndo();
            FrameEditor.Delete(_project.Frames, Indices(args));
            return Changed(args);
        });
        _bridge.On("frames.toggleMarker", args =>
        {
            PushUndo();
            FrameEditor.ToggleMarker(_project.Frames, Indices(args));
            return Changed(args);
        });
        _bridge.On("frames.clearMarkers", args =>
        {
            PushUndo();
            FrameEditor.ClearMarkers(_project.Frames);
            return Changed(args);
        });
        _bridge.On("frames.clearOverrides", args =>
        {
            PushUndo();
            FrameEditor.ClearOverrides(_project.Frames, Indices(args));
            return Changed(args);
        });
        // Per-frame tone: the selected frames get their own complete tone, locked against later
        // global changes. "undo": false while a slider is being dragged (one undo step per edit).
        _bridge.On("frames.setTone", args =>
        {
            if (BridgeHost.Arg(args, "undo", true)) PushUndo();
            var tone = new ToneSettings(
                Math.Clamp(BridgeHost.Arg(args, "method", 0), 0, ToneMethod.Count - 1), BridgeHost.Arg(args, "flags", 0),
                BridgeHost.Arg(args, "contrast", 0), BridgeHost.Arg(args, "brightness", 0),
                BridgeHost.Arg(args, "gamma", 100), BridgeHost.Arg(args, "strength", ToneAdjust.StrengthDefault));
            foreach (int i in Indices(args))
                if (i >= 0 && i < _project.Frames.Count) _project.Frames[i].LockTone(tone);
            return Changed(args);
        });
        _bridge.On("frames.clearTone", args =>
        {
            PushUndo();
            foreach (int i in Indices(args))
                if (i >= 0 && i < _project.Frames.Count) _project.Frames[i].ClearTone();
            return Changed(args);
        });
        // The tone a frame uses now (its own, or the global one).
        _bridge.On("frames.toneOf", args =>
        {
            int i = BridgeHost.Arg(args, "index", -1);
            if (i < 0 || i >= _project.Frames.Count) return null;
            var f = _project.Frames[i];
            var t = FrameBuilder.Resolve(f, _process.ToProcessSettings(_settings.RotateCw)).Tone;
            return new { method = t.Method, flags = t.Flags, contrast = t.Contrast, brightness = t.Brightness,
                         gamma = t.Gamma, strength = t.Strength, own = f.HasToneOverride };
        });
        _bridge.On("frames.setOverride", args =>
        {
            int rotation = BridgeHost.Arg(args, "rotation", 0);
            bool flipH = BridgeHost.Arg(args, "flipH", false), negative = BridgeHost.Arg(args, "negative", false);
            PushUndo();
            foreach (int i in Indices(args))
            {
                if (i < 0 || i >= _project.Frames.Count) continue;
                var f = _project.Frames[i];
                f.HasOverride = true; f.Rotation = rotation; f.FlipH = flipH; f.FlipV = false; f.Negative = negative;
            }
            return Changed(args);
        });
        _bridge.On("frames.clearExported", _ =>
        {
            foreach (var f in _project.Frames) f.IsExported = false;
            return _project.Frames;
        });
        _bridge.On("frames.list", _ => _project.Frames);

        // Lazarus frame tools: E merge pairs, J combine overlapping, S split, Z suggested, Ctrl+Z undo.
        _bridge.On("frames.merge", args => WithSelection(args, () => FrameEditor.MergePairs(_project.Frames, Indices(args))));
        _bridge.On("frames.combine", args => WithSelection(args, () => FrameEditor.CombineOverlapping(_project.Frames, Indices(args))));
        _bridge.On("frames.split", args => WithSelection(args,
            () => FrameEditor.Split(_project.Frames, Indices(args), Math.Clamp(BridgeHost.Arg(args, "parts", 2), 2, 10000))));
        _bridge.On("frames.toggleSuggested", args =>
        {
            PushUndo();
            FrameEditor.ToggleSuggested(_project.Frames, BridgeHost.Arg(args, "index", -1));
            return Changed(args);
        });
        // Repair tools (Lazarus Framing tab): fill gaps, join close, expand, trim, sections.
        _bridge.On("frames.closeGaps", args =>
        {
            PushUndo();
            var (changed, keep) = FrameRepair.CloseGaps(_project.Frames, Indices(args));
            Changed(args);
            return new { frames = _project.Frames, count = changed, select = SelectIndices(keep) };
        });
        _bridge.On("frames.joinClose", args =>
        {
            PushUndo();
            var (runs, removed, keep) = FrameRepair.JoinClose(_project.Frames, Indices(args), Math.Max(0, BridgeHost.Arg(args, "gap", 600L)));
            Changed(args);
            return new { frames = _project.Frames, runs, count = removed, select = SelectIndices(keep) };
        });
        _bridge.On("frames.expand", args =>
        {
            PushUndo();
            var (changed, keep) = FrameRepair.Expand(_project.Frames, Indices(args), _project.Roll,
                BridgeHost.Arg(args, "lead", 0), BridgeHost.Arg(args, "trail", 0),
                BridgeHost.Arg(args, "left", 0), BridgeHost.Arg(args, "right", 0));
            Changed(args);
            return new { frames = _project.Frames, count = changed, select = SelectIndices(keep) };
        });
        _bridge.On("frames.trim", args =>
        {
            PushUndo();
            int n = FrameRepair.Trim(_project.Frames, BridgeHost.Arg(args, "minLeft", 0), BridgeHost.Arg(args, "maxRight", 0));
            Changed(args);
            return new { frames = _project.Frames, count = n };
        });
        _bridge.On("frames.section", args =>
        {
            var (start, end) = FrameRepair.Section(_project.Frames, BridgeHost.Arg(args, "index", -1), BridgeHost.Arg(args, "includeSuggested", true));
            if (start < 0) throw new BridgeException("No folder marker before this frame.");
            return new { start, end };
        });
        _bridge.On("frames.deleteSection", args =>
        {
            var (start, end) = FrameRepair.Section(_project.Frames, BridgeHost.Arg(args, "index", -1), includeSuggested: false);
            if (start < 0) throw new BridgeException("No yellow marker found before this frame.");
            PushUndo();
            int count = end - start + 1;
            _project.Frames.RemoveRange(start, count);
            FrameEditor.Refresh(_project.Frames);
            Changed(args);
            return new { frames = _project.Frames, count };
        });
        _bridge.On("frames.clearExportedOn", args =>
        {
            var only = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("indices", out _) ? Indices(args).ToHashSet() : null;
            for (int i = 0; i < _project.Frames.Count; i++)
                if (only is null || only.Contains(i)) _project.Frames[i].IsExported = false;
            _bridge.Emit("frames.changed", new { source = BridgeHost.Arg(args, "source", "main") });
            return _project.Frames;
        });

        // User key bindings (command id -> keys); defaults live in wwwroot/js/keymap.js.
        _bridge.On("settings.keymap", args =>
        {
            _settings.KeyBindings = BridgeHost.Arg(args, "bindings", new Dictionary<string, List<string>>());
            _settings.Save();
            _bridge.Emit("keymap.changed", _settings.KeyBindings);
            return null;
        });

        // Folder-marker suggestions (Lazarus "Suggest Markers" and the suggested clean-up tools).
        _bridge.On("markers.suggest", args =>
        {
            PushUndo();
            var r = MarkerSuggester.Suggest(_project.Frames,
                Math.Clamp(BridgeHost.Arg(args, "strictness", MarkerSuggester.StrictnessDefault), MarkerSuggester.StrictnessMin, MarkerSuggester.StrictnessMax),
                BridgeHost.Arg(args, "beforeGap", false), BridgeHost.Arg(args, "direction", 0), BridgeHost.Arg(args, "anchor", -1));
            Changed(args);
            return new { frames = _project.Frames, suggested = r.Suggested, threshold = r.GapThreshold };
        });
        _bridge.On("markers.clearSuggested", args =>
        {
            PushUndo();
            bool selectedOnly = BridgeHost.Arg(args, "selectedOnly", false);
            int n = MarkerSuggester.ClearSuggested(_project.Frames, selectedOnly ? Indices(args) : null);
            Changed(args);
            return new { frames = _project.Frames, count = n };
        });
        _bridge.On("markers.clearSuggestedEvery", args =>
        {
            PushUndo();
            int n = MarkerSuggester.ClearSuggestedEvery(_project.Frames, BridgeHost.Arg(args, "anchor", -1),
                BridgeHost.Arg(args, "direction", 1), BridgeHost.Arg(args, "every", 2));
            Changed(args);
            return new { frames = _project.Frames, count = n };
        });
        _bridge.On("markers.clearToward", args =>
        {
            PushUndo();
            int n = MarkerSuggester.ClearMarkersToward(_project.Frames, BridgeHost.Arg(args, "anchor", -1), BridgeHost.Arg(args, "direction", 1));
            Changed(args);
            return new { frames = _project.Frames, count = n };
        });
        _bridge.On("markers.acceptSuggested", args =>
        {
            // Turn every suggestion into a folder marker (same as Select suggested + A).
            PushUndo();
            int n = 0;
            foreach (var f in _project.Frames.Where(f => f.IsSuggested)) { f.IsMarker = true; f.IsSuggested = false; n++; }
            Changed(args);
            return new { frames = _project.Frames, count = n };
        });

        _bridge.On("frames.undo", args =>
        {
            if (_undo.Count == 0) throw new BridgeException("Nothing to undo.");
            _project.Frames = _undo[^1];
            _undo.RemoveAt(_undo.Count - 1);
            FrameEditor.Refresh(_project.Frames);
            Changed(args);
            return new { frames = _project.Frames, remaining = _undo.Count };
        });

        // Separate preview window
        _bridge.On("preview.open", args => { _host.OpenPreview(BridgeHost.Arg(args, "index", 0)); return null; });
        _bridge.On("preview.close", _ => { _host.ClosePreview(); return null; });
        // Main-window selection follows into the preview, but only when it is already open.
        _bridge.On("preview.follow", args =>
        {
            if (_host.Preview is not null) _bridge.Emit("preview.show", new { index = BridgeHost.Arg(args, "index", 0) });
            return null;
        });
        _bridge.On("preview.frame", args => PreviewFrameInfo(BridgeHost.Arg(args, "index", 0)));
        _bridge.On("preview.select", args => { _bridge.Emit("preview.selected", new { index = BridgeHost.Arg(args, "index", 0) }); return null; });
        _bridge.On("preview.loaded", args => { _bridge.Emit("preview.loaded", args.Clone()); return null; });
        _bridge.On("preview.settings", args =>
        {
            _settings.PreviewTopmost = BridgeHost.Arg(args, "topmost", _settings.PreviewTopmost);
            _settings.PreviewStep = Math.Clamp(BridgeHost.Arg(args, "step", _settings.PreviewStep), 1, 1000);
            _settings.PreviewFullQuality = BridgeHost.Arg(args, "fullQuality", _settings.PreviewFullQuality);
            _host.SetPreviewTopmost(_settings.PreviewTopmost);
            return null;
        });
        _bridge.On("preview.orient", args =>
        {
            // Per-frame orientation from the preview: R / Rot -90, M mirror, N negative.
            int i = BridgeHost.Arg(args, "index", -1);
            if (i < 0 || i >= _project.Frames.Count) return null;
            PushUndo();
            var f = _project.Frames[i];
            if (!f.HasOverride)
            {
                // Start from the global settings so the first click changes only one thing.
                f.HasOverride = true; f.Rotation = _process.Rotation; f.FlipH = _process.Mirror; f.FlipV = false; f.Negative = _process.Negative;
            }
            f.Rotation = (((f.Rotation + BridgeHost.Arg(args, "rotate", 0)) % 360) + 360) % 360;
            if (BridgeHost.Arg(args, "mirror", false)) f.FlipH = !f.FlipH;
            if (BridgeHost.Arg(args, "negative", false)) f.Negative = !f.Negative;
            Changed(args);
            return PreviewFrameInfo(i);
        });

        _bridge.On("app.setTheme", args =>
        {
            _settings.Theme = BridgeHost.Arg(args, "theme", "dark") == "light" ? "light" : "dark";
            _host.ApplyTheme(_settings.Theme == "dark");
            _bridge.Emit("theme.changed", new { theme = _settings.Theme });
            _settings.Save();
            return null;
        });

        _bridge.On("process.set", args =>
        {
            _process = BridgeHost.Args<ProcessDto>(args);
            _process.StoreTo(_project.Roll);
            MarkDirty();
            ++_imageVersion;
            // Tell every page: the preview window must rebuild its frame with the new tone.
            _bridge.Emit("images.changed", new { imageVersion = _imageVersion });
            return new { imageVersion = _imageVersion };
        });
        _bridge.On("view.set", args =>
        {
            bool rotate = BridgeHost.Arg(args, "rotateCw", _settings.RotateCw);
            if (rotate != _settings.RotateCw)
            {
                _imageVersion++;
                _bridge.Emit("images.changed", new { imageVersion = _imageVersion });
            }
            _settings.RotateCw = rotate;
            _settings.StripsPerRow = Math.Clamp(BridgeHost.Arg(args, "stripsPerRow", _settings.StripsPerRow), 1, 20);
            _settings.Zoom = Math.Clamp(BridgeHost.Arg(args, "zoom", _settings.Zoom), 0.25, 4.0);
            _settings.FrameFillOpacity = Math.Clamp(BridgeHost.Arg(args, "frameFillOpacity", _settings.FrameFillOpacity), 0, 100);
            _settings.AutoStrips = BridgeHost.Arg(args, "autoStrips", _settings.AutoStrips);
            _settings.ShowStripNumbers = BridgeHost.Arg(args, "showStripNumbers", _settings.ShowStripNumbers);
            _settings.MultiEdit = BridgeHost.Arg(args, "multiEdit", _settings.MultiEdit);
            return new { imageVersion = _imageVersion };
        });
        _bridge.On("notes.set", args =>
        {
            string md = BridgeHost.Arg(args, "markdown", "");
            if (md != _project.Notes) { _project.Notes = md; MarkDirty(); }
            return null;
        });
        _bridge.On("export.settings", args =>
        {
            _export = BridgeHost.Args<ExportDto>(args);
            StoreExportToRollAndSettings();
            _bridge.Emit("export.changed", null); // the preview's target banner follows naming changes
            return null;
        });

        _bridge.OnAsync("detect.run", args => RunDetectionAsync(BridgeHost.Args<DetectDto>(args)));
        _bridge.On("detect.cancel", _ => { _detectCts?.Cancel(); return null; });

        _bridge.On("export.start", args => StartExport(BridgeHost.Args<ExportDto>(args)));
        _bridge.On("export.preview", args => PreviewExportPath(BridgeHost.Arg(args, "index", 0), BridgeHost.Args<ExportDto>(args)));
        _bridge.On("export.prepareFolders", args => PrepareFolders(BridgeHost.Args<ExportDto>(args)));
        _bridge.On("export.pause", _ => { _exportEngine?.Pause(); return null; });
        _bridge.On("export.resume", _ => { _exportEngine?.Resume(); return null; });
        _bridge.On("export.cancel", _ => { _exportEngine?.Resume(); _exportCts?.Cancel(); return null; });

        _bridge.On("dialog.pickFolder", args =>
        {
            var dlg = new OpenFolderDialog { Title = "Choose output folder" };
            string initial = BridgeHost.Arg(args, "initial", "");
            if (Directory.Exists(initial)) dlg.InitialDirectory = initial;
            return dlg.ShowDialog(_owner) == true ? dlg.FolderName : null;
        });
        _bridge.On("shell.openFolder", args => { Shell.OpenFolder(BridgeHost.Arg(args, "path", "")); return null; });
        _bridge.On("shell.openUrl", args => { Shell.OpenUrl(BridgeHost.Arg(args, "url", "")); return null; });
    }

    private static List<int> Indices(JsonElement args) => BridgeHost.Arg(args, "indices", new List<int>());

    /// <summary>Copies the fields the page may edit; flags computed here (oversize etc.) are left alone.</summary>
    private static void CopyEditable(FrameRecord src, FrameRecord dst)
    {
        dst.LeadEdge = src.LeadEdge; dst.TrailEdge = src.TrailEdge;
        dst.LeftEdge = src.LeftEdge; dst.RightEdge = src.RightEdge;
        dst.IsMarker = src.IsMarker; dst.IsSuggested = src.IsSuggested;
    }

    private void MarkDirty()
    {
        if (_dirty) return;
        _dirty = true;
        _bridge.Emit("project.dirty", true);
    }

    /// <summary>
    /// After any frame edit: mark dirty and tell every page (the other window refreshes),
    /// then hand the new list to the page that asked.
    /// </summary>
    private object Changed(JsonElement args)
    {
        MarkDirty();
        _bridge.Emit("frames.changed", new { source = BridgeHost.Arg(args, "source", "main") });
        return _project.Frames;
    }

    private object WithSelection(JsonElement args, Func<List<FrameRecord>> edit)
    {
        PushUndo();
        var keep = edit();
        Changed(args);
        return new { frames = _project.Frames, select = keep.Select(f => _project.Frames.IndexOf(f)).Where(i => i >= 0).ToList() };
    }

    private List<int> SelectIndices(IEnumerable<FrameRecord> keep) =>
        keep.Select(f => _project.Frames.IndexOf(f)).Where(i => i >= 0).ToList();

    private void PushUndo()
    {
        _undo.Add(_project.Frames.Select(f => f.Clone()).ToList());
        if (_undo.Count > UndoSteps) _undo.RemoveAt(0);
    }

    /// <summary>Everything the preview window shows about one frame.</summary>
    private object? PreviewFrameInfo(int index)
    {
        var frames = _project.Frames;
        if (!_project.Roll.Loaded || frames.Count == 0) return null;
        index = Math.Clamp(index, 0, frames.Count - 1);
        var f = frames[index];
        var p = FrameBuilder.Resolve(f, _process.ToProcessSettings(_settings.RotateCw));
        bool quarter = p.Rotation is 90 or 270;
        string path = "", pathError = "", folder = "", fileName = "", root = "";
        var naming = _export.ToNaming(ExportNaming.DefaultOutputRoot(ProjectRootPath, _project.Roll));
        root = naming.OutputRoot;
        try
        {
            var target = ExportNaming.PathForFrame(frames, index, naming);
            path = target.FullPath;
            fileName = target.FileName;
            // Target folder relative to the output root: what the operator compares with the page.
            folder = Path.GetRelativePath(root, target.FolderPath);
            if (folder == ".") folder = "";
        }
        catch (InvalidOperationException e) { pathError = e.Message; }
        var (volume, fileNo) = ExportNaming.VolumeAndFile(frames, index);
        int folderCount = ExportNaming.VolumeAndFile(frames, frames.Count - 1).Volume;
        int rowCount = ExportNaming.ArchiveRows(_export.ArchiveList).Count;
        return new
        {
            index, count = frames.Count, frame = f, volume, fileNo, path, pathError,
            target = new
            {
                root, folder, fileName, folderCount, namingMode = _export.NamingMode,
                rowCount, segments = folder.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries),
            },
            prevMarker = FrameEditor.FindMarker(frames, index, forward: false),
            nextMarker = FrameEditor.FindMarker(frames, index, forward: true),
            width = quarter ? f.Width : (int)f.Height, height = quarter ? (int)f.Height : f.Width,
            rotation = p.Rotation, mirror = p.FlipH, negative = p.Negative, ownOrientation = f.HasOverride,
            imageVersion = _imageVersion,
            settings = new { topmost = _settings.PreviewTopmost, step = _settings.PreviewStep, fullQuality = _settings.PreviewFullQuality, theme = _settings.Theme, keyBindings = _settings.KeyBindings },
        };
    }

    private SessionDto Session() => new(
        _project.Roll, _project.Frames, _project.Notes, _projectPath, _idfPath,
        ExportNaming.DefaultOutputRoot(ProjectRootPath, _project.Roll),
        _process, _export, _imageVersion, _dirty);

    private string ProjectRootPath => _projectPath != "" ? _projectPath : _idfPath;

    // ------------------------------------------------------------ open / save

    private object? OpenProject(string path)
    {
        if (!ConfirmDiscardOrSave("opening another roll")) return null;
        if (string.IsNullOrEmpty(path))
        {
            var dlg = new OpenFileDialog
            {
                Title = "Open roll",
                Filter = "Striplight rolls (*.slf;*.idf;*.qpf)|*.slf;*.idf;*.qpf|Striplight project (*.slf)|*.slf|" +
                         "QuantumScan roll (*.idf)|*.idf|QuantumScan project (*.qpf)|*.qpf|All files (*.*)|*.*",
            };
            if (Directory.Exists(_settings.LastFolder)) dlg.InitialDirectory = _settings.LastFolder;
            if (dlg.ShowDialog(_owner) != true) return null;
            path = dlg.FileName;
        }
        if (!File.Exists(path)) throw new BridgeException("File not found: " + path);

        string ext = Path.GetExtension(path).ToLowerInvariant();
        Project project;
        string projectPath = "", idfPath = "";
        if (ext == ".idf")
        {
            idfPath = path;
            // A Striplight project saved next to the IDF wins: it holds the edited frames.
            string slf = ProjectFile.SlfPathForIdf(path);
            if (File.Exists(slf) && ProjectFile.TryLoadProject(slf, out project))
            {
                projectPath = slf;
                _bridge.Emit("toast", $"Opened the saved project {Path.GetFileName(slf)} for this roll.");
            }
            else
            {
                var r = IdfParser.Parse(path, out var roll, out var frames);
                if (r != IdfParseResult.Ok) throw new BridgeException(IdfParser.Message(r));
                project = new Project { Roll = roll, Frames = frames, SourceIdfPath = path };
            }
        }
        else
        {
            if (!ProjectFile.TryLoadProject(path, out project))
                throw new BridgeException("Could not read the project file " + Path.GetFileName(path) + ".");
            if (ext == ".slf") projectPath = path;
            idfPath = File.Exists(project.SourceIdfPath) ? project.SourceIdfPath : "";
        }

        // Strips live next to the IDF. If the project was saved elsewhere, look there.
        if (idfPath != "")
        {
            string idfDir = RollPaths.WithTrailingSeparator(Path.GetDirectoryName(Path.GetFullPath(idfPath))!);
            project.Roll.BasePath = idfDir;
            project.Roll.PreviewBasePath = idfDir;
            project.Roll.PreviewSourceBasePath = idfDir;
            if (project.Roll.StripCount <= 0 && IdfParser.Parse(idfPath, out var idfRoll, out _) == IdfParseResult.Ok)
                project.Roll.StripCount = idfRoll.StripCount;
        }
        project.Roll.Loaded = true;
        FrameEditor.Refresh(project.Frames);

        _project = project;
        _undo.Clear();
        _projectPath = projectPath;
        _idfPath = idfPath;
        _dirty = false;
        _process = ProcessDto.FromRoll(project.Roll);
        _export = ExportFromSettings(project.Roll);
        _imageVersion++;
        _settings.LastFolder = Path.GetDirectoryName(Path.GetFullPath(path)) ?? "";
        _settings.AddRecent(path);
        _settings.Save();
        return Session();
    }

    private ExportDto ExportFromSettings(RollData roll) => new()
    {
        NamingMode = roll.ExportNamingMode, ArchiveList = roll.ArchiveList, Progressive = roll.ExportProgressive,
        Prefix = _settings.Prefix, FileDigits = _settings.FileDigits, SeparateFolders = _settings.SeparateFolders,
        Quality = _settings.Quality, SkipExisting = _settings.SkipExisting,
        AllowPreviewFallback = _settings.AllowPreviewFallback, LocalTempStage = _settings.LocalTempStage,
        Workers = _settings.Workers, StripCacheLimit = _settings.StripCacheLimit,
    };

    private void StoreExportToRollAndSettings()
    {
        var r = _project.Roll;
        if (r.ExportNamingMode != _export.NamingMode || r.ArchiveList != _export.ArchiveList ||
            r.ExportProgressive != _export.Progressive)
        {
            r.ExportNamingMode = _export.NamingMode;
            r.ArchiveList = _export.ArchiveList;
            r.ExportProgressive = _export.Progressive;
            if (r.Loaded) MarkDirty();
        }
        _settings.Prefix = _export.Prefix; _settings.FileDigits = _export.FileDigits;
        _settings.SeparateFolders = _export.SeparateFolders; _settings.Quality = _export.Quality;
        _settings.SkipExisting = _export.SkipExisting; _settings.AllowPreviewFallback = _export.AllowPreviewFallback;
        _settings.LocalTempStage = _export.LocalTempStage; _settings.Workers = _export.Workers;
        _settings.StripCacheLimit = _export.StripCacheLimit;
    }

    private object? Save(bool saveAs)
    {
        if (!_project.Roll.Loaded) throw new BridgeException("Open a roll first.");
        string target = _projectPath;
        if (saveAs || target == "")
        {
            string suggested = _projectPath != "" ? _projectPath
                : _idfPath != "" ? ProjectFile.SlfPathForIdf(_idfPath)
                : Path.Combine(_project.Roll.BasePath, _project.Roll.RollName + ".slf");
            var dlg = new SaveFileDialog
            {
                Title = "Save roll project",
                Filter = "Striplight project (*.slf)|*.slf|QuantumScan project (*.qpf)|*.qpf",
                FileName = Path.GetFileName(suggested),
                InitialDirectory = Path.GetDirectoryName(suggested) ?? "",
                AddExtension = true,
            };
            if (dlg.ShowDialog(_owner) != true) return null;
            target = dlg.FileName;
        }

        _process.StoreTo(_project.Roll);
        string sourceIdf = _idfPath != "" ? _idfPath : _project.SourceIdfPath;
        if (Path.GetExtension(target).Equals(".qpf", StringComparison.OrdinalIgnoreCase))
        {
            // QPF is QuantumScan's format: no notes, no Striplight-only fields. The project stays unsaved as SLF.
            ProjectFile.SaveQpf(target, sourceIdf, _project);
            _bridge.Emit("toast", $"Exported QuantumScan project {Path.GetFileName(target)}.");
            return new { path = target, dirty = _dirty };
        }

        ProjectFile.SaveSlf(target, sourceIdf, _project);
        _projectPath = target;
        _dirty = false;
        _settings.AddRecent(target);
        _settings.Save();
        _bridge.Emit("project.dirty", false);
        return new { path = target, dirty = false };
    }

    private object? CloseProject()
    {
        if (!ConfirmDiscardOrSave("closing the roll")) return null;
        _project = new Project();
        _projectPath = _idfPath = "";
        _dirty = false;
        return new { closed = true };
    }

    /// <summary>Asks to save unsaved changes. Returns false when the user cancels.</summary>
    public bool ConfirmDiscardOrSave(string action)
    {
        if (!_dirty || !_project.Roll.Loaded) return true;
        var answer = MessageBox.Show(_owner,
            $"The roll \"{_project.Roll.RollName}\" has unsaved changes.\n\nSave them before {action}?",
            "Striplight PRO", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.Cancel) return false;
        if (answer == MessageBoxResult.Yes)
        {
            try { return Save(saveAs: false) is not null; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                MessageBox.Show(_owner, "Saving failed: " + e.Message, "Striplight PRO", MessageBoxButton.OK, MessageBoxImage.Error);
                return false;
            }
        }
        return true;
    }

    public void Shutdown()
    {
        _detectCts?.Cancel();
        _exportCts?.Cancel();
        _settings.Save();
    }

    // ------------------------------------------------------------ detection

    private async Task<object?> RunDetectionAsync(DetectDto d)
    {
        var roll = _project.Roll;
        if (!roll.Loaded) throw new BridgeException("Open a roll first.");
        if (_detectCts is not null) throw new BridgeException("Detection is already running.");

        int to = d.StripTo < 0 ? roll.StripCount - 1 : d.StripTo;
        var tone = _process;
        var options = new DetectOptions
        {
            StripFrom = d.StripFrom, StripTo = to,
            MinWidthPx = d.MinWidth, MinHeightPx = d.MinLength, Threshold = d.Threshold,
            // Detection sees what the strip view shows: the same tone curve (method, sliders,
            // rescue curves). Tune for white frames on a black background, then detect.
            // With "Striplight current" this is identical to the Lazarus detection formula.
            ToneLut = d.UseToneSliders
                ? ToneAdjust.BuildLut(ToneAdjust.IsAdaptive(tone.Method) ? ToneMethod.Striplight : tone.Method,
                    tone.Flags, tone.Contrast, tone.Brightness, tone.Gamma)
                : null,
            MergeAcrossGaps = d.TouchLength >= 0 ? d.TouchLength : roll.LengthLines / 64,
            LeftInsetPx = d.LeftInset, RightInsetPx = d.RightInset,
            MinRunPx = Math.Max(0, d.MinRun), TouchWidthPx = Math.Max(0, d.TouchWidth),
            MaxLengthPx = Math.Max(0, d.MaxLength),
            OverscanWidthPx = d.OverscanWidth, OverscanLengthPx = d.OverscanLength,
            Invert = d.Invert, AutoThreshold = d.AutoThreshold,
        };
        roll.DetectionThreshold = d.Threshold;
        roll.DetectMinWidth = d.MinWidth;
        roll.DetectMinLength = d.MinLength;

        var rollCopy = roll.Clone();
        _detectCts = new CancellationTokenSource();
        long lastEmit = 0;
        var live = new List<FrameRecord>();   // frames detected so far (copies)
        int sent = 0;                          // how many of them the page already has
        var progress = new Progress<DetectProgress>(p =>
        {
            if (p.NewFrames is not null)
            {
                live.RemoveRange(p.FromIndex, live.Count - p.FromIndex);
                live.AddRange(p.NewFrames);
            }
            // Long rolls have thousands of strips: send at most ~10 updates a second, each with
            // the frames the page has not seen yet (plus the last one again, it may have grown).
            long now = Environment.TickCount64;
            if (now - lastEmit < 100 && p.CurrentStrip < p.TotalStrips) return;
            lastEmit = now;
            int fromIdx = Math.Max(0, Math.Min(sent, live.Count) - 1);
            _bridge.Emit("detect.progress", new
            {
                p.CurrentStrip, p.TotalStrips, p.StripsRead, p.StripsMissing, p.FramesFound, p.StripIndex,
                fromIndex = fromIdx, frames = live.Skip(fromIdx).ToList(),
            });
            sent = live.Count;
        });
        try
        {
            var found = await Task.Run(() => FrameDetector.Detect(rollCopy, options,
                i =>
                {
                    string p = RollPaths.PreviewFilePath(rollCopy, i);
                    return File.Exists(p) ? TurboJpeg.DecodeFile(p, TurboJpeg.PixelFormatBgra) : null;
                },
                progress, _detectCts.Token));
            PushUndo();
            FrameEditor.ReplaceDetectedRange(_project.Frames, found, options.StripFrom, options.StripTo, roll.LengthLines);
            MarkDirty();
            _bridge.Emit("frames.changed", new { source = "main" });
            // Read vs. missing previews make path problems visible (e.g. previews on another share).
            int read = 0, missing = 0;
            for (int i = options.StripFrom; i <= options.StripTo; i++)
                if (File.Exists(RollPaths.PreviewFilePath(rollCopy, i))) read++; else missing++;
            return new
            {
                frames = _project.Frames, found = found.Count, read, missing,
                previewFolder = Path.GetDirectoryName(RollPaths.PreviewFilePath(rollCopy, options.StripFrom)),
                threshold = options.Threshold,
            };
        }
        catch (OperationCanceledException)
        {
            return new { frames = _project.Frames, found = -1 };
        }
        finally
        {
            _detectCts.Dispose();
            _detectCts = null;
        }
    }

    // ------------------------------------------------------------ export

    private object PreviewExportPath(int index, ExportDto dto)
    {
        if (!_project.Roll.Loaded || index < 0 || index >= _project.Frames.Count) return new { path = "" };
        // Folder count: every marker starts a folder; frames before the first marker share folder 1.
        int markers = _project.Frames.Count(f => f.IsMarker);
        int folders = Math.Max(1, markers + (_project.Frames.Count > 0 && !_project.Frames[0].IsMarker && markers > 0 ? 1 : 0));
        int rows = ExportNaming.ArchiveRows(dto.ArchiveList).Count;
        try
        {
            var naming = dto.ToNaming(ExportNaming.DefaultOutputRoot(ProjectRootPath, _project.Roll));
            return new { path = ExportNaming.PathForFrame(_project.Frames, index, naming).FullPath, folders = ExportNaming.VolumeAndFile(_project.Frames, _project.Frames.Count - 1).Volume, rows };
        }
        catch (InvalidOperationException e) { return new { path = "", error = e.Message, folders, rows }; }
    }

    /// <summary>"Prepare folders" (Lazarus): creates every output folder of the export before running it.</summary>
    private object PrepareFolders(ExportDto dto)
    {
        if (!_project.Roll.Loaded || _project.Frames.Count == 0) throw new BridgeException("There are no frames to export.");
        var naming = dto.ToNaming(ExportNaming.DefaultOutputRoot(ProjectRootPath, _project.Roll));
        IEnumerable<int> indices = dto.Scope == "selected" ? dto.Indices : Enumerable.Range(0, _project.Frames.Count);
        List<ExportJob> jobs;
        try { jobs = ExportEngine.BuildJobs(_project.Frames, indices, naming); }
        catch (InvalidOperationException e) { throw new BridgeException("Export path error: " + e.Message); }
        var folders = jobs.Select(j => j.FolderPath).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var f in folders) Directory.CreateDirectory(f);
        return new { created = folders.Count, root = naming.OutputRoot };
    }

    private object StartExport(ExportDto dto)
    {
        var roll = _project.Roll;
        if (!roll.Loaded) throw new BridgeException("Open a roll first.");
        if (_exportCts is not null) throw new BridgeException("An export is already running.");
        if (!TurboJpeg.IsAvailable) throw new BridgeException(TurboJpeg.Status);
        if (_project.Frames.Count == 0) throw new BridgeException("There are no frames to export.");

        _export = dto;
        StoreExportToRollAndSettings();
        _settings.Save();

        var naming = dto.ToNaming(ExportNaming.DefaultOutputRoot(ProjectRootPath, roll));
        IEnumerable<int> indices = dto.Scope == "selected" ? dto.Indices : Enumerable.Range(0, _project.Frames.Count);
        List<ExportJob> jobs;
        try { jobs = ExportEngine.BuildJobs(_project.Frames, indices, naming); }
        catch (InvalidOperationException e) { throw new BridgeException("Export path error: " + e.Message); }
        if (jobs.Count == 0) throw new BridgeException("No frames selected for export.");

        foreach (var f in _project.Frames) f.IsExported = false;
        var process = _process.ToProcessSettings(_settings.RotateCw);
        var options = dto.ToOptions();
        _exportEngine = new ExportEngine();
        _exportCts = new CancellationTokenSource();
        int done = 0;
        var progress = new Progress<ExportJobResult>(r =>
        {
            done++;
            if (r.Outcome == ExportOutcome.Exported && r.Job.FrameIdx < _project.Frames.Count)
                _project.Frames[r.Job.FrameIdx].IsExported = true;
            _bridge.Emit("export.progress", new
            {
                done, total = jobs.Count, frameIdx = r.Job.FrameIdx, outcome = r.Outcome.ToString(),
                error = r.Error, path = r.Job.FullPath,
            });
        });

        var frames = _project.Frames;
        _ = Task.Run(async () =>
        {
            ExportSummary? summary = null;
            string? fatal = null;
            try { summary = await _exportEngine.RunAsync(roll, frames, jobs, process, options, progress, _exportCts.Token); }
            catch (Exception e) { fatal = e.Message; }
            _owner.Dispatcher.Invoke(() =>
            {
                _bridge.Emit("export.done", new
                {
                    exported = summary?.Exported ?? 0, skipped = summary?.Skipped ?? 0, failed = summary?.Failed ?? 0,
                    cancelled = summary?.Cancelled ?? false, seconds = summary?.Elapsed.TotalSeconds ?? 0,
                    failures = summary?.Failures.Select(f => new { frameIdx = f.Job.FrameIdx, path = f.Job.FullPath, error = f.Error }),
                    fatal, outputRoot = naming.OutputRoot,
                });
                _exportCts?.Dispose();
                _exportCts = null;
                _exportEngine = null;
            });
        });
        return new { jobs = jobs.Count, outputRoot = naming.OutputRoot };
    }
}

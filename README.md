# Striplight

Windows desktop tools for reviewing scanned microfilm strips, detecting and adjusting frame boundaries, and exporting frame images. Built with Lazarus and Free Pascal.

This repository preserves the working source snapshot backed up on 2026-10-27.

## Build and restore

Verified environment: Windows x64, Lazarus 2.2.4, Free Pascal 3.2.2, BGRAControls 7.5 and BGRABitmap 11.5.2.

1. Clone this repository.
2. Install Lazarus with its matching Free Pascal compiler.
3. Install/register BGRAControls and BGRABitmap using Lazarus Online Package Manager. The main project requires `bgracontrols` and `LCL`.
4. Open `Striplight.lpi` in Lazarus and build, or run these commands in PowerShell from the repository directory:

```powershell
& 'C:\lazarus\lazbuild.exe' --build-all --no-write-project Striplight.lpi
& 'C:\lazarus\lazbuild.exe' --build-all --no-write-project StriplightCacheManager.lpi
```

Adjust the Lazarus path for your installation. If using a separate Lazarus profile, pass `--pcp=<profile-directory>` for the profile where the BGRA packages are registered. A fresh empty profile will report a broken dependency even when those packages are installed elsewhere.

Keep `libturbojpeg.dll` beside `Striplight.exe`. The included DLL is the Windows x64 runtime from the local libjpeg-turbo 3.2.0 distribution. Its license notices are in `docs/third-party/`.

`StriplightIcon.res` and the application resource files are included. To regenerate the icon resource after changing `Striplight.ico`, use the resource compiler supplied with your Lazarus/FPC installation on `StriplightIcon.rc`.

## Contents

- `Striplight.lpi` / `Striplight.lpr`: main application.
- `StriplightCacheManager.lpi` / `.lpr`: standalone cache manager.
- `uMainForm.pas` / `.lfm`: main interface and export workflow.
- `uStripView.pas`: strip display and preview rendering.
- `uFrameDetect.pas`: frame detection.
- `uIDFParser.pas`, `uQPF.pas`, `uTypes.pas`: file parsing, project data and shared types.
- `uTurboJPEG.pas`: TurboJPEG runtime interface.
- `uToneAdjust.pas`, `uToneBitmap.pas`: tone adjustment methods shared by preview and export.
- `uTurboRaw.pas`, `uFrameGray.pas`: fast grayscale export path and shared strip cache.
- `tests/striplight_tests.lpr`: command-line checks, tone-method tryout and benchmark.
- `docs/tone_methods_and_fast_export.md`: the adaptive tone methods and the fast export path.
- `uStandaloneCacheManager.pas`: cache-manager interface.
- `unit1.pas` / `.lfm`: preserved original starter form, unused by the current projects.
- `assets/`: original icon and artwork assets.
- `future_export_and_detection_ideas.md`: historical design ideas; not a description of current feature completeness.
- `docs/striplight_curve_csv_analysis.md` and `docs/curve.csv`: tone-curve analysis and its input data.
- `docs/BACKUP.md`: backup scope and verification record.

## Future backups

This is a snapshot, not automatic synchronization. After editing this checkout, commit and push changes to GitHub. Changes made in another local copy must first be copied here or committed from a checkout connected to this repository.

Generated executables, compiler output, IDE sessions, logs and sample scans are intentionally excluded. Rebuild executables from the preserved source. Original local files remain in place.

# Backup record — 2026-10-27

The current source and project files were copied byte-for-byte from the working Striplight folder, together with form definitions, resources, the runtime DLL, artwork and development notes. The curve analysis and its CSV input were also preserved from the parent working folder.

## Scope

Includes both the main Striplight application and the standalone cache manager. Older backup folders, duplicate executables, the source ZIP, sample scan JPEGs, compiler caches, temporary Lazarus profiles and the complete third-party installer/SDK are not part of this source backup. Those local files were not deleted or moved.

The root `libturbojpeg.dll` matches the DLL in the local libjpeg-turbo 3.2.0 installation. SHA-256:

```
4FD997C7EEC636D3C48A9FC604B6CB573DA030F2F6382D4ED07397C7D7F4E50E
```

Its upstream notices are preserved in `third-party/LICENSE.md` and `third-party/README.ijg`. These notices apply to the third-party library; this backup does not assign a new license to Striplight.

## Verification

The original main project was rebuilt successfully on 2026-10-27 with Lazarus 2.2.4 / FPC 3.2.2 on Windows x64: 15,717 lines compiled, with hints and notes. No source modifications were needed. Builds use the existing Lazarus profile with BGRAControls 7.5 and BGRABitmap 11.5.2 registered.

Compilation checks establish that the preserved source can build with these dependencies. They do not constitute a runtime regression test or preserve scanned work documents and user project data.

The prepared repository copy was also rebuilt successfully for both projects: Striplight (15,717 lines) and StriplightCacheManager (1,178 lines), each with exit code 0.

# Lumora (codename)

A native macOS app that imports the user's **own** existing Wallpaper Engine wallpapers
(from the local Steam Workshop folder already synced to disk) and renders them — **video,
web, and scene** types — as live desktop wallpapers behind the icons.

> Codename only. This project is **not affiliated with Wallpaper Engine or Valve** and will
> never use that name/logo. It reads only files the user already has on disk; it does not
> download, host, or redistribute content.

## Status
The core engine is in place. The license firewall is CI-enforced; `WECore` holds the shared contracts
and `WallpaperShell` owns the desktop window (multi-display, occlusion/battery/thermal playback policy,
login item) under a runnable menu-bar app. `WEImporter` (importer), `WEShaderKit` (WE-dialect
shader→MSL transpiler), `WEScene` (clean-room Metal scene renderer), `WESceneDynamics`
(particles/audio/scenescript), and `WEPlayers` (video/web/scene players) are all implemented and
exercised by per-package `*Checks` targets. Remaining work is the product layer — playlists, timed
rotation, transitions, live playback UI — plus the signed `.app` packaging that needs full Xcode.
See the implementation plan and `CONTRIBUTING.md`.

## Architecture in one line
Thin menu-bar app → local Swift packages whose **dependency graph is the license boundary**
(permissive MIT/Apache-2.0 only; the only complete reference, `linux-wallpaperengine`, is
GPL-3.0 and is consulted **only** for its documented formats and observable behavior — never
copied). This keeps a future Mac App Store / commercial release possible.

## Building (Command Line Tools; no Xcode required for the packages)
This environment has CLT only, so `XCTest`/`swift test` are unavailable; verification runs through
small executable `*Checks` targets instead. One command runs everything:
```sh
bash Scripts/check_all.sh   # firewall audit + every package's *Checks + LumoraApp build
```
Individually (each package has its own `<Pkg>Checks` executable; `LumoraApp` is build-only):
```sh
cd Packages/WECore          && swift run WECoreChecks           # core contracts
cd Packages/WallpaperShell  && swift run WallpaperShellChecks   # desktop window / policy / coordinator
cd Packages/WEImporter      && swift run WEImporterChecks       # .pkg / scene / texture parsing
cd Packages/WEShaderKit     && swift run WEShaderKitChecks      # WE-shader → MSL transpiler
cd Packages/WEScene         && swift run WESceneChecks          # clean-room Metal scene renderer
cd Packages/WESceneDynamics && swift run WESceneDynamicsChecks  # particles / audio / scenescript
cd Packages/WEPlayers       && swift run WEPlayersChecks        # video / web / scene players
cd Packages/LumoraApp       && swift build                      # menu-bar app (compile only)
bash Scripts/audit_licenses.sh                                 # license firewall gate
```

### Running the menu-bar app
```sh
cd Packages/LumoraApp && swift run LumoraApp
```
A status-bar item appears and a wallpaper window is placed behind the icons on every display and
Space, pausing when occluded / on screen sleep and throttling on battery. Point it at a library with
`LUMORA_LIBRARY_DIR=<path-to-workshop-folder> swift run LumoraApp` to render real wallpapers.
(Login-item registration and notarization need a real signed `.app` bundle built with full Xcode.)

The packaged `.app`, code-signing, and notarization require full Xcode and an Apple Developer ID.

## Layout
```
Packages/        local SPM packages (each with its own LICENSE + SPDX headers)
Scripts/         audit_licenses.sh (blocking firewall gate)
LICENSES/        THIRD_PARTY.md ledger
docs/parity/     pixel-parity harness docs (Windows capture SOP, etc.)
provenance.json  per-module provenance (spec doc | permissive repo | clean-room)
```

# Lumora (codename)

A native macOS app that imports the user's **own** existing Wallpaper Engine wallpapers
(from the local Steam Workshop folder already synced to disk) and renders them — **video,
web, and scene** types — as live desktop wallpapers behind the icons.

> Codename only. This project is **not affiliated with Wallpaper Engine or Valve** and will
> never use that name/logo. It reads only files the user already has on disk; it does not
> download, host, or redistribute content.

## Status
**Phase 0 complete** — license firewall (CI-enforced), `WECore` contracts, `WallpaperShell`
(desktop window, multi-display, occlusion/battery playback policy, login item), and a runnable
menu-bar app that owns the desktop. Pixel-parity harness scaffolding in place. Next: Phase 1
(video player + importer + library). See the implementation plan and `CONTRIBUTING.md`.

## Architecture in one line
Thin menu-bar app → local Swift packages whose **dependency graph is the license firewall**
(permissive MIT/Apache-2.0 only; the only complete reference, `linux-wallpaperengine`, is
GPL-3.0 and used **only** as a behavioral oracle + public docs — never copied). This keeps a
future Mac App Store / commercial release legally possible.

## Building (Command Line Tools; no Xcode required for the packages)
This environment has CLT only, so `XCTest`/`swift test` are unavailable; verification runs through
small executable `*Checks` targets instead. One command runs everything:
```sh
bash Scripts/check_all.sh   # firewall audit + WECore/WallpaperShell checks + LumoraApp build
```
Individually:
```sh
cd Packages/WECore         && swift run WECoreChecks          # core contract checks
cd Packages/WallpaperShell && swift run WallpaperShellChecks  # policy/coordinator checks
cd Packages/LumoraApp      && swift build                     # menu-bar app (compile)
bash Scripts/audit_licenses.sh                                # license firewall gate
```

### Running the menu-bar app (Phase 0 "own the desktop")
```sh
cd Packages/LumoraApp && swift run LumoraApp
```
A status-bar item appears; a black wallpaper window is placed behind the icons on every display and
Space, pausing when occluded / on screen sleep and throttling on battery. (Login-item registration
and notarization need a real signed `.app` bundle built with full Xcode — Phase 5.)

The packaged `.app`, code-signing, and notarization require full Xcode and an Apple Developer ID.

## Layout
```
Packages/        local SPM packages (each with its own LICENSE + SPDX headers)
Scripts/         audit_licenses.sh (blocking firewall gate)
LICENSES/        THIRD_PARTY.md ledger
docs/parity/     pixel-parity harness docs (Windows capture SOP, etc.)
provenance.json  per-module provenance (spec doc | permissive repo | clean-room)
```

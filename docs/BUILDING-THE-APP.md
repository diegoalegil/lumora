# Building Lumora.app (local, no Apple Developer account)

This produces a real, double-clickable **`Lumora.app`** you can run on your own Mac. It is **ad-hoc signed**
(`codesign -s -`) and **not notarized** — so it costs nothing (no $99/yr Apple Developer Program), but Gatekeeper
will ask you to confirm it the first time, and you can't hand it to other people for friction-free install. That's
the trade-off for skipping notarization; everything else works.

## Requirements

- The Swift toolchain that ships with **Xcode** *or* the **Command Line Tools** (`xcode-select --install`).
- `codesign` and `iconutil` (both included with the above).
- *Optional:* Python + Pillow (`pip3 install pillow`) to (re)generate the placeholder icon. If it's missing the
  build still works — it just reuses the committed `app/AppIcon.icns`.

## Build

```sh
bash Scripts/build_app.sh
```

That compiles `LumoraApp` in release, assembles `build/Lumora.app` (Info.plist + icon + the binary), and ad-hoc
signs it. Pass an output directory to put it elsewhere, e.g. `bash Scripts/build_app.sh ~/Applications`.

## Run it the first time

macOS blocks unsigned/un-notarized apps on a plain double-click. Once, do **either**:

- **Right-click** `Lumora.app` → **Open** → **Open** in the dialog, **or**
- `xattr -dr com.apple.quarantine build/Lumora.app && open build/Lumora.app`

After that it launches normally. A **status-bar item** appears and the wallpaper renders behind your desktop
icons. Drag `Lumora.app` to `/Applications` if you want it to live there (and for "Launch at Login" to be stable).

## What's in the bundle

```
Lumora.app/Contents/
  Info.plist              # bundle id com.diegoalegil.lumora, menu-bar (LSUIElement) app, macOS 14+
  MacOS/Lumora            # the compiled binary
  Resources/Lumora.icns   # the app icon
  _CodeSignature/         # the ad-hoc signature
```

## Notes & limitations (without notarization)

- **No auto-update.** Re-run `Scripts/build_app.sh` to rebuild after pulling new code.
- **The icon is a placeholder** (a crescent — "Lumora" = light). Replace `app/AppIcon.icns` with real branding;
  `python3 app/make_icon.py` regenerates the placeholder if you want to tweak it.
- **Login-item / Screen-Recording permission:** an ad-hoc signature is enough to *run*, but macOS ties the
  "Launch at Login" registration and any TCC permission prompts to the bundle id + signature, so they're most
  reliable once the app sits in a fixed location (e.g. `/Applications`).
- **Distributing to other people later** is the only thing that needs the paid path: a Developer ID signature +
  `notarytool` + `stapler` (then a `.dmg`). The bundle this script makes is already shaped for that — only the
  signing identity changes.

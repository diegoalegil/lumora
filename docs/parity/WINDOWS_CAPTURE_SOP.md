# Windows reference-capture SOP (pixel-parity harness)

The authoritative parity target is **Wallpaper Engine running on Windows** (you own it). This SOP makes
captures reproducible so macOS output can be diffed against them deterministically. The
`linux-wallpaperengine` binary is only a *secondary* black-box cross-check (it has its own bugs and
"Partial" scene/web support) — never the primary target, and we never read its source.

> Commit only `parity/corpus/manifest.json` (and, if you want, reference-frame **SHA-256 hashes**). Never
> commit the captured pixels or the wallpaper assets (copyright). `.gitignore` keeps `parity/captures/` and
> any `we-reference/` dir out of the tree.

## The runner exists (Swift, no Python)
The SSIM/MAE comparator is built into `WESceneChecks`:
```sh
cd Packages/WEScene && swift run -q WESceneChecks <library-dir> parity <we-reference-dir>
```
It renders each `<library-dir>/<id>/scene.pkg` at **its reference frame's resolution**, computes mean SSIM
(structure) and MAE (colour/tone) against the reference, prints them worst-first, and fails if any scene
falls below the SSIM floor. A scene with no reference frame is skipped, so it runs incrementally as captures
arrive. `check_all.sh` runs it automatically when `LUMORA_WE_REFERENCE` points at the capture dir.

## Prerequisites
- Wallpaper Engine on Windows, with the corpus wallpapers subscribed/installed.
- Capture resolution **1920×1080** (any consistent size works — the macOS side renders at the reference's
  own resolution — but 1920×1080 is the standard).
- **No mouse cursor** in the capture, and **no audio** playing. Both are out of scope on the macOS side
  (a desktop wallpaper has no live cursor, and Lumora plays no wallpaper audio), so a capture with cursor
  parallax or audio reactivity would diff against a deliberately static render. Disable Windows display
  scaling artifacts (capture the raw framebuffer).

## Per-wallpaper procedure
1. **Apply the wallpaper** in WE at 1920×1080 with **default properties** (note any non-default in `notes`).
2. Let it settle, cursor parked off-frame, no audio. Capture **one lossless PNG** — the composition/parity
   baseline. This single still is what the gate compares.
3. **Animated scenes** (particles, scripted motion): the still above is enough for the structural gate.
   Optionally also grab a short clip/burst so motion can be eyeballed separately — the SSIM gate itself
   compares stills, not motion.

## Naming & placement
The gate looks for a reference, in order: `<we-reference-dir>/<id>.png`, then `<id>/static.png`, then
`<id>/<id>.png`. The simplest layout is one PNG per scene named by its workshop id:
```
we-reference/3669680904.png
we-reference/2111201226.png
```
(`<id>/static.png` also works if you prefer a folder per scene.) Then point the gate at that dir:
```sh
LUMORA_WE_REFERENCE=/path/to/we-reference bash Scripts/check_all.sh
# or directly:
cd Packages/WEScene && swift run -q WESceneChecks "$PWD/../../431960" parity /path/to/we-reference
```

## Still pending
- The reference frames themselves (this capture pass).
- Per-tier thresholds in `gates.yaml` are not yet consumed — the runner uses a single SSIM floor; tighten it
  once a real corpus is measured.

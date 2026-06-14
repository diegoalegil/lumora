# Windows reference-capture SOP (pixel-parity harness)

The authoritative parity target is **Wallpaper Engine running on Windows** (you own it). This SOP
makes captures reproducible so macOS output can be diffed against them deterministically. The
`linux-wallpaperengine` binary is only a *secondary* black-box cross-check (it has its own bugs and
"Partial" scene/web support) — never the primary target, and we never read its source.

> We commit only `parity/corpus/manifest.json` + reference-frame **SHA-256 hashes**. We never commit
> the captured pixels or the wallpaper assets (copyright). `.gitignore` enforces this.

## Prerequisites
- Wallpaper Engine on Windows, with the wallpapers in the corpus subscribed/installed.
- A fixed capture resolution: **1920×1080** (the harness renders macOS output at the same size).
- Disable the mouse cursor in captures; disable Windows scaling artifacts (capture the raw output).

## Per-wallpaper procedure
For each entry in `manifest.json`, capture the listed `reference_frames`. Each frame is a still PNG.

1. **Apply the wallpaper** in WE at 1920×1080, default properties (note any non-default in `notes`).
2. **Static sub-case** (`static`): for scene/web, freeze interaction — center the cursor, no audio
   playing — and capture one frame after it settles. This is the composition/parity baseline.
3. **Timeline sub-case** (`t=2.0s`, `t=5.0s`): for animated scenes, capture at known elapsed times
   from wallpaper start (use a stopwatch / OBS frame marker). These map to the macOS
   `ParityRenderer`'s injected `RenderClock` times.
4. **Mouse sub-case** (`mouse=0.25,0.5` etc.): move the cursor to the listed normalized position and
   capture, to validate parallax. Matches the injected `MouseProvider`.
5. **Audio sub-case** (`audio=tone440`): play the standard reference tone (`docs/parity/tone440.wav`,
   a 440 Hz sine) and capture, to validate audio reactivity. Matches the injected
   `AudioSpectrumProvider` synthetic spectrum.

## Naming & placement
Save captures under `parity/captures/<workshop_id>/<frame_name>.png` (git-ignored), e.g.:
```
parity/captures/861750235/static.png
parity/captures/1108769435/t=2.0s.png
```
Then register their hashes:
```sh
python3 parity/tools/register_frames.py 861750235   # (added in Phase 3) hashes + updates manifest.json
```

## How the harness uses these
The macOS `ParityRenderer` (in WEScene, Phase 3+) renders each wallpaper headlessly to a PNG at the
same resolution, with the same injected time/mouse/audio. `parity/tools/run.py` (Phase 3) computes
SSIM + per-pixel MAE + CIELAB ΔE against the Windows reference, applies the per-feature thresholds in
`gates.yaml`, and writes `win | mac | diff-heatmap` contact sheets. A phase ships only when its gate
is green; PRs fail on regression vs `baseline.json`.

Prerequisites for the diff tools (build-time only, not shipped): `numpy`, `scikit-image` (BSD).

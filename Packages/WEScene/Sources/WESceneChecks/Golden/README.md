<!-- SPDX-License-Identifier: MIT -->
<!-- Provenance: clean-room. Author-generated golden references for the WEScene compositing pipeline. -->

# Golden references

Each `*.rgba` file is a tightly-packed 16×16 RGBA8 frame (1024 bytes) rendered by `WESceneChecks`
from a synthetic, **author-defined** scene — there are no Wallpaper Engine pixels here, so these are
firewall-safe. Every scene is a full-screen uniform-texture quad, so the whole frame is one 8-bit-unorm
integer blend result that reproduces byte-for-byte across GPUs (no bilinear-filtering ULP); the gate
allows a max per-channel delta of 2 only to absorb cross-driver rounding.

| File | What it pins |
|------|--------------|
| `over_alpha_half.rgba` | "over" blend + a known straight-alpha composite (green @ 0.5 over red) |
| `over_opaque_tint.rgba` | the per-object colour tint (white × (0.5, 0.25, 1)) |
| `additive.rgba` | additive blend (red sprite added over a blue clear) |

Regenerate after an **intentional** change to the blend / alpha / tint pipeline:

```sh
cd Packages/WEScene && LUMORA_REGEN_GOLDEN=1 swift run -q WESceneChecks
```

Without that environment variable the committed references gate the render: a pipeline regression makes
`WESceneChecks` (and therefore `check_all.sh`) fail.

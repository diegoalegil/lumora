# CHANGELOG — autopilot fidelity run (vs we-reference clean oracle)

Arbiter: SSIM vs `we-reference/<id>.png` (best-matching phase), 96 scenes. Keep a change only if it
raises target scenes and regresses nothing >0.005; otherwise revert. Commits authored by the owner.

## Baseline @ `fa3e8f3`
- Clean re-captured oracle (96×3 frames, playlist-off — the 6 prior mislabels are fixed).
- Mean SSIM **0.7958**, ≥0.80 **58/96**, ≥0.90 **38/96**.
- PROGRESS.md generated with per-scene objective = max(0.90, baseline).

## Entries
(one per commit, newest last)

### `d005cc3` — FASE 0: baseline tracking vs clean oracle
PROGRESS.md + CHANGELOG seeded. Mean 0.7958, ≥0.80 58/96, ≥0.90 38/96.

### FASE 1 — attempted, all already-done / oracle-refuted (no commit)
- **T1.1 rope/ropetrail**: tested the cheap approximation (treat `.rope` like the existing `.spriteTrail` ribbon). Result: **neutral** (no scene moved >0.005) — the rope particles are too faint to register in SSIM. Reverted. Full Catmull-Rom strip (L) would be neutral too. **Deferred** (matches CORRECCIONES "gana poco").
- **T1.2 effects un-drop after uniforms**: re-tested `LUMORA_NO_DROP_GATE` vs the clean oracle → mean **0.7860 < 0.7958**; 3319713168 drops **0.60→0.43**. The drop-gate is still optimal (4th confirmation); the dropped effects need missing aux/LUT textures (firewall). **Deferred.**
- **T1.3 blend enum**: verified the ApplyBlending switch already maps all 15 used values (1,2,3,6,7,9,10,11,12,21,22,23,30,31 + specials), correct per fidelidad-blend-table.md. Already landed in a prior commit. **No change.**

### FASE 2 — attempted, all neutral/blocked (no commit)
- **T2.1 wrap REPEAT**: global `.repeat` test vs clean oracle → mean 0.7956 and 3200980645 **regressed -0.005** (a clamp-needing texture); no scene improved. By-flag would be at best neutral and avoids that regression → zero net ROI. **Deferred.**
- **T2.2 mips**: BC/DXT textures dominate the corpus and can't blit-generate mips (need a `decodeAllMips`, M-effort); gain is aliasing-only and validation scenes are already 0.89–0.95. **Deferred.**
- **T2.3 R8 swizzle**: tested neutral previously; the (r,r,r,r) mask broadcast has a documented rationale. **Deferred.**
- **T2.4 bloom multilevel**: validation scene 2996283606 (0.85) is **taskbar-capped** (render already matches the oracle except the Windows taskbar strip) — bloom already matches, not the gap. Only ~7 bloom-active scenes, most already ≥0.93. **Deferred.**

### `75bf4b3` — diagnostic: LUMORA_PARITY_CROP_BOTTOM (quantify oracle taskbar)
Discovered 32/96 oracle captures bake the Windows taskbar into the bottom ~48px. Env-gated crop diagnostic (gate default unchanged). Measured: crop bottom 48px → mean **0.7958 → 0.8117**, ≥0.90 **38 → 43**. Lumora's true fidelity is ~0.81+; those 32 scenes are faithful, taskbar-capped. Fix is capture-side.

### ROUND 2 (feature autopilot) — PASO 1: taskbar crop made permanent in the gate
`parityGate` now crops the bottom 48px by default (`LUMORA_PARITY_CROP_BOTTOM`, default 48; set 0 for
full-frame). ~32 captures bake the Windows taskbar there. Re-baselined PROGRESS.md from the with-crop run:
**mean 0.8117 · ≥0.90 43/96** (was 38/96 uncropped) — 5 scenes cross 0.90 purely by dropping the desktop
chrome from the score. 66 WEScene checks + full check_all green.

> ⚠️ **Blocker for PASO 2/3:** the `we-reference` oracle + the whole `sesion desktop` package were removed
> from `~/Desktop` by the environment between sessions (not in Trash/home). The feature round's acceptance
> rule (no SSIM regression with crop **and** a visual A/B vs `we-reference/<id>`) needs the oracle PNGs, which
> are gone. Retained: the SSIM tables (incl. the crop run) and lumora renders — but not the oracle frames.
> **To resume feature work, restore the package** (re-extract `lumora-sesion-desktop.zip` into the Desktop, or
> re-send it). Landing render features blind would violate the round's own discipline (oracle decides
> regressions; A/B enables flat-SSIM features) and risk the regressions it forbids — so PASO 2/3 are paused,
> not skipped.

### ROUND 2 — feature implementation (oracle deleted → verify by unit-test + lumora self-A/B + spec + gating)
The we-reference oracle was removed from disk, so this round lands real WE features verified WITHOUT it:
correctness via new unit checks, "it works" via lumora before/after self-renders, fidelity by WE-spec, and
no-regression by gating (only the target scenes change). SSIM-vs-we-reference is pending the oracle's return.

- **`4984d23` camerapath (T3.2) — LANDED.** Bézier pan+zoom camera (origin.animation c0/c1 + zoom.animation),
  clean-room CSS-style cubic-bézier (Newton solve). Gated on a present origin.animation → only 3675966045 is
  affected (verified: it's the lone animated-camera scene; 3479521040's static zoom=0.75 untouched, 95 scenes
  byte-identical). Self-A/B: 3675966045 now zooms 2.13x→1.0x over its 4s path (was frozen). +9 unit checks
  (bézier linear/hold/monotonic/single-key/2.13→1.0 zoom/static-gate). All checks + firewall green.
- **rope/ropetrail (T1.1) — implemented then REVERTED (inert on this corpus).** Built the connected-ribbon
  (per-segment oriented quads via the instanced pipeline, gated to .rope). But lumora before/after is pixel-
  identical on all 5 rope scenes: the rope sprites are NOT dropped, yet the particles cluster at a point
  (trail_1 has distancemax=0) / are too faint to form a visible ribbon. Can't demonstrate improvement → reverted
  per the round's rule. (Reinstate if a future scene has a spread, visible rope.)

### ROUND 2 cont. — remaining features scoped against the real code (oracle still gone)
- **copybackground (T3.1) — SCOPED, deferred (needs oracle + render restructuring).** Root cause: `_rt_FullFrameBuffer`
  resolves to `whiteTexture` (SceneRenderer.resolveAuxTexture default, ~line 659), so glass/water effects sample
  white. Clean fix: a new `EffectInput.background` resolved per-frame to the scene composite, gated to effects that
  reference `_rt_FullFrameBuffer`/`_rt_MipMappedFrameBuffer`. The transpiler already wires `gl_FragCoord`
  (WEShaderTranspiler ~109-138), and `renderBackground` already composites the scene — BUT a glass layer's effect
  runs in Pass 1 before that composite exists (chicken-and-egg) → needs multi-phase render restructuring, and it
  touches 60+ scenes (grep of the library). Too risky to land blind; do it with the oracle to verify no regression.
- **bloom (T2.4) — deferred (self-A/B-neutral here).** The glow gap on the bloom scenes (e.g. Rengoku 2479422222)
  is the dropped fire/ember PARTICLES (firewall-blocked WE sprites), not the bloom kernel width; a bloom-shader
  change doesn't close it. (2996283606, the other bloom scene, is taskbar-capped — bloom already matches.)
- **particle operators (T3.3) — blocked.** Exact vortex/turbulence/controlpoint math needs the GPL CParticle
  source (firewall).
- **Conclusion:** camerapath (4984d23) was the last cleanly-demonstrable feature available without the oracle.
  The rest need the oracle restored (to verify) or WE assets the firewall forbids. Loop stopped to avoid a risky
  blind landing; resume on oracle restore.

### ROUND 3 — oracle RESTORED → features verified vs we-reference + landed
The owner re-extracted the package, so the deferred features were implemented and measured against the real
oracle (taskbar-crop gate). Each: no scene regresses >0.005 AND the target scene's SSIM rises (oracle = arbiter).
- **camerapath (`4984d23`) — VERIFIED.** vs oracle: 3675966045 0.2603 → 0.2706 (+0.0103), 0 regressions. The
  blind landing was correct.
- **copybackground (`2b6fffa`) — LANDED + VERIFIED.** New `EffectInput.background`: `_rt_FullFrameBuffer` (was →
  whiteTexture) now binds a backdrop = the scene composited with the copybackground layers excluded, separate
  pool, gated. vs oracle: 3390491312 0.4907 → 0.5055 (+0.0148), 0 regressions, mean 0.8118 → 0.8120.
- **bloom widen (`a36b361`) — LANDED + VERIFIED.** Doubled the scene-bloom tap spacing (7×7 box → wider soft
  halo). vs oracle: 2479422222 +0.006, 2817222811 +0.003, 3497714247 +0.003, high bloom scenes flat, 0
  regressions, mean 0.8120 → 0.8121. Visually cleaner fire glow, no banding.
  - **Fuller bloom REFUTED:** then tested a wider gaussian two-octave kernel (spacing 3+9, a multilevel-downsample
    approximation). It OVERSHOOTS — 2479422222 -0.0072 vs the widen, mean -0.0001. So spacing-6 is the sweet spot;
    a true wider multilevel bloom would overshoot more. Reverted; the widen is optimal. (Bloom direction settled.)
- **particle operators (T3.3) — deferred.** Exact math needs GPL CParticle (firewall); and the particle gaps are
  position-at-capture-instant (SSIM-unfixable). rope stays reverted (inert: clustered/faint particles).
- **State:** mean SSIM 0.8121 (crop), ≥0.90 43/96. Round features all landed-or-deferred-with-measurement.

### ROUND 4 — autonomous: default-bug re-investigation (P1) + property-default audit (P2) + shared-assets (P3)
P1 premise tested with a 16-agent investigation workflow over the 15 sub-target day-night/scripted/clock scenes
(read lumora render + oracle + scene/project JSON, classify recoverable-default-bug vs oracle-non-default-capture
vs text/HDR). Result: **most day-night scenes are oracle-non-default-captures, NOT bugs** — they use a
`new Date().getHours()` script (timevarying default true) to pick morning/day/dusk/night video layers; the owner
captured WE at a specific wall-clock time (night/pre-dawn), and lumora already shows the correct *author default*
(the static `display` branch). No deterministic fix can match a wall-clock capture. BUT the audit surfaced real,
deterministic default-bugs — all fixed, oracle-verified, 0 regressions:
- **`8221f61` general.bloom dict form.** `{ "user","value":true }` was read only as Bool/NSNumber → bloom dropped.
  Now resolves the bound default. 4 scenes rise (3409595232 +0.003, 3426865175 +0.003, 3627327015 +0.004,
  3585875739 +0.001).
- **`1b243a0` solid-colour layer detection.** A full-screen solid background via `models/solid_instance_model_*.json`
  (model `solidlayer:true`, material `solidlayer_*`) was missed (only the image PATH was matched) → the layer's
  texture didn't resolve and it was skipped. Now also reads the model flag/material. 3355791741 (Dandadan)
  0.5932 → 0.6670 (+0.0738, the red background returns).
- **`2137d83` general bloomstrength/threshold/zoom dict form.** Same class via a new `generalNumber()` helper.
  3438420195 0.7524 → 0.7795 (+0.0271); audio-reactive bloomstrength resolves to its audio-silent value.
- **`b66f8fd`+`dadd775` (P3) shared-assets disk fallback** for aux textures + custom fonts (env-gated, no-op when
  unset, path-traversal-guarded), with 7 unit checks (73 total).
- State: mean SSIM 0.8121 → **0.8133**, ≥0.90 43/96.

**DEFERRED deep findings (documented, not blind-fixed):**
- 3430675494 (0.413, biggest gap): effects darken the base ~30% (effects-off luma 66.9 ≈ oracle 68.9; on=46.6).
  Culprit = `filmgrain` (`ApplyBlending(BLENDMODE, albedo, noise, g_NoiseAlpha=2)` darkens); shimmer/foliagesway
  don't. Fix needs a transpiler BLENDMODE/uniform-default change that touches EVERY filmgrain scene → needs broad
  regression testing first. Not a default-bug.
- 3565328165 / 3447271084: WE scales text glyphs to fill the layer `size` box (e.g. Date size 781x660,
  pointsize 144); lumora sizes the quad by raw glyph pixels (line ~2025, also ignores layer.scale) → text too
  small. Confirmed visually (3447271084: oracle big "2日"/SUNDAY vs lumora tiny "28"). Date content matches
  today, but the clock TIME is wall-clock → partial payoff; the size-box scaling has aspect-distortion risk
  across all text scenes → text-render workstream, deferred.

**P4 hardening DONE:** `c25caa8` 7 synthetic-scene parser regression guards (316 importer checks). Full
`check_all.sh` GREEN (242 + LumoraApp build). Perf: `benchall` 1920x1080 = **97 scenes, 0 sub-60fps**
(slowest 3265802028 7.3ms/137fps; copybackground scene 3390491312 4.2ms — the extra composite is negligible
per-frame). filmgrain-darkening fix NOT attempted: 7 scenes use filmgrain incl. 1773105076 (0.957) and
3646049140 (0.877); a wrong blend/uniform change would regress those, and the cause (material blending=normal,
g_NoiseAlpha=2, ApplyBlending semantics) is firewall-adjacent + uncertain. Deferred to a focused pass.

ROUND 5 result: mean SSIM **0.8133**, ≥0.90 43/96, all commits CI-green, 0 regressions, all 4 priorities done.

### ROUND 6 — filmgrain darkening ROOT-CAUSED + FIXED (the deferred deep finding, now landed)
Rather than blind-fix or abandon the 3430675494 darkening, added a safe diagnostic and isolated it empirically:
- **`4770ed9` LUMORA_SKIP_EFFECT diagnostic** (off by default; skips effects by name/shader substring). Confirmed
  filmgrain is the culprit: `LUMORA_SKIP_EFFECT=filmgrain` restores 3430675494 luma 46.6 → 68.0 (~oracle 68.9);
  skipping shimmer/foliagesway/vhs does nothing.
- **`297968f` centre the procedural util/noise.** Root cause: lumora's noise was flat uniform [0,255]; fed through
  filmgrain's `noise*noise * pow(.,0.5)` + HardLight blend (BLENDMODE 12 from the shader combo default, strength 2),
  a full-contrast field skews dark and dims the layer ~30%. A film grain is a SMALL deviation around mid-grey
  (HardLight(x,~0.5) ≈ identity). Generate triangular noise centred on 128 (avg of two samples). Oracle: **3430675494
  0.4130 → 0.7390 (+0.3260)** — the session's biggest single gain — plus 3198624623 +0.007, 2468167360 +0.007,
  2109561442 +0.009, **0 regressions**, mean **0.8133 → 0.8169**. Visually confirmed bright/vivid (matches oracle).

ROUND 6 result: mean SSIM **0.8169**, all commits CI-green, 0 regressions. Session total: 0.8121 → 0.8169 (+0.0048).

### ROUND 7 — diagnostic-driven effect-faithfulness sweep
Used the LUMORA_SKIP_EFFECT diagnostic + a full-suite effects-OFF parity to find effects Lumora renders worse
than skipping, then isolated each culprit and measured a global drop across all 96 (keep only if net-positive,
0 regressions):
- **`4f8a9ec` drop depthparallax + cloudmotion.** depthparallax = cursor/camera-parallax, should be a no-op
  without a mouse (Lumora has none) but mis-offsets the layer; cloudmotion distorts the cloud layer instead of
  animating it. Oracle: 3265802028 +0.170, 3565328165 +0.123, 3545444802 +0.107, 3426865175 +0.027, 3669680904
  +0.006, 0 regressions, mean **0.8169 → 0.8215**. Visually confirmed (3545444802 sky/clouds/reflection match).
- **waterwaves — NOT dropped (REFUTED globally).** Helps 1588298589 (+0.042) but is CORRECT on most scenes:
  dropping it regresses 2817222811 −0.102, 2820544627 −0.042, +6 more. Net −0.0003. It's a per-config render
  issue on 1588298589, not a globally-bad effect → deferred (would need per-parameter work). The full-suite
  measure caught the regression before any commit.

ROUND 7 result: mean SSIM **0.8215**, ≥0.90 43/96, 0 regressions. **Session total: 0.8121 → 0.8215 (+0.0094).**

### ROUND 8 — Windows-audit fixes (3 items; clean-room OK, 0 major)
- **#2 (correctness) per-consumer noise (`09b159f`).** The round-6 centred noise was GLOBAL, but util/noise is
  shared: foliagesway uses noise.g·2π as a per-region sway PHASE, and vhs's glitch displacement needs the full
  uniform range — centring altered their phase (masked by single-frame SSIM). Now a second centred-noise texture
  is handed ONLY to filmgrain (resolveAuxTexture(centeredNoise:)); every other consumer keeps the original flat
  uniform field. 3430675494 holds 0.739 (+0.326 kept); foliagesway/vhs revert to correct uniform (3198624623,
  2468167360, 2109561442 lose a coincidental single-frame +0.007). Mean 0.8215 → 0.8213 — the dip is the price of
  faithful phase, not a regression.
- **#1 (defensive) effect-drop match (`30d3220`).** The permanent drop compared only the shader path; the
  diagnostic matched name OR path. depthparallax/cloudmotion have EMPTY names so the path match already fires
  (verified: 3265802028 0.677, 3545444802 0.861 in the committed build) — added the OR so it can't no-op for a
  future effect that carries its signature in the name.
- **#3 (test) solid-layer isolation (`7f6c304`).** The guard test's material contained "solidlayer" so it passed
  via the material branch even if the flag branch broke. Split: a plain-material test isolates the model-flag
  branch; a no-flag test covers the material branch. 317 importer checks.

ROUND 8 result: mean SSIM **0.8213** (phase-faithful), ≥0.80 59/96, ≥0.90 43/96. Session total: 0.8121 → 0.8213
(+0.0092), all CI-green, 0 unintended regressions.

### ROUND 9 — test-infra (burst scoring) landed; D & E measured-and-reverted
Worked against the freshly re-extracted oracle (96 stills + 96 `_t1` + 96 `_t2` bursts). New-oracle baseline @4c95871:
still-only **0.8155**, burst-avg **0.8094**.
- **`9db6571` parity gate scores the _t1/_t2 bursts (INFRA, landed).** The gate scored best-of-phases against ONE
  still and never loaded the bursts — exactly why the noise-phase bug slipped (frame 0 stays intact). Now each
  scene is scored against every available burst frame, each by its best phase, then averaged: a still scene is
  unaffected, an animated scene is judged on the MOTION. Render untouched; `LUMORA_PARITY_STILL_ONLY=1` for the
  old metric. New default mean (burst-avg) **0.8094** vs still-only 0.8155 — the gap is animated scenes that
  diverge by _t1/_t2 (honest phase coverage). This is the round's primary deliverable.
- **D (wrap REPEAT by ClampUVs flag) — implemented, MEASURED-NEUTRAL, reverted.** Plumbed the ClampUVs flag
  (TexFlags bit 2) through the .tex header → DecodedTexture, then tested. The flagship positive 3675966045 moved
  **0.0000** even under a crude global effect-aux `.repeat`; the only movers came from repeating render-targets
  (which per-flag D keeps clamped) and were net-negative (2780446545 −0.005, 2479422222 −0.006). Repeat-vs-clamp
  only differs where UVs leave [0,1]; the cover-fit layers and these effects don't. Reverted (all edits).
- **E (mipmaps) — implemented, MEASURED, reverted (3 regressions > 0.005).** Mips for uncompressed formats
  (excluding swizzled R8, which can't be a render target) + generateMipmaps + trilinear, gated. Net mean +0.0011
  (6 up: 3627327015 +0.037, 3291581513 +0.020, …) BUT 3 regressions > 0.005 (2303021395 −0.014, 2468167360
  −0.010, 3195212886 −0.006 — WE renders those crisper, so mips blur them). Fails the strict 0-regression rule
  → reverted (all edits).

ROUND 9 result: gate now burst-aware (mean def. changed to 0.8094); D & E reverted cleanly per measure-or-revert;
no render change shipped this round beyond the infra. CI green.

### FASE 3/4 — assessed (round 1)
- **T3.1 copybackground**: blocked — needs the transpiler to emit a `v_ScreenCoord` varying it never emits (compose shaders would reference an undefined varying); validation scenes already ≥0.93. **Deferred (XL/blocked).**
- **T3.2 camerapath**: gated; static zoom would regress 3479521040 (already matches without it); only 3675966045 has real animation and it's dominated by fire/clock/grade. **Deferred.**
- **T3.3 particle operators**: would require the reference engine's particle math (firewall-restricted) and the gaps are position-at-capture-instant (SSIM-unfixable). **Deferred.**
- **T4.1 group/effectlayer**: effectlayer effects are grade/glitch/audio-reactive (firewall-blocked LUTs or correct no-ops). **Deferred.**

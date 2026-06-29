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

**Burst-metric caveat (triaged the biggest still→burst gaps).** The burst-avg is best for REGRESSION DETECTION,
not as an absolute fidelity number: it penalizes scenes whose `_t1`/`_t2` animate via something lumora correctly
excludes or can't reproduce. The two largest gaps are both NON-bugs: 1683040946 (gap 0.28) has an "Ember"
particle layer — firewall-dropped fire particles animate between frames; 2238042939 (gap 0.41) is a single
static image, NO effects/audio/script, lumora correctly static and matching WE's still at 0.997, but WE's _t1 is
+22 luma (idle camera-drift / capture exposure). Neither is fixable. So the 0.8094 under-counts true fidelity on
animated scenes the same way the still metric under-counts audio-visualiser/firewall-particle scenes — use it to
catch a change that WORSENS motion, and keep `LUMORA_PARITY_STILL_ONLY=1` (0.8155) for the static-fidelity view.

### ROUND 10 — FUENTES (shared fonts) measured-refuted + MAPA-TECHO ceiling map
- **FUENTES (shared-font fallback) — REFUTED as an SSIM lever.** The P3 fallback wiring is live, so this was a
  pure measurement: `LUMORA_SHARED_ASSETS_DIR=<we-shared-assets>` and A/B the 21 candidate scenes, burst-avg vs
  oracle. Result: **0 scenes up/down > 0.005** (max +0.0008 on 3195212886); 8 scenes re-rasterise with the correct
  font (the fallback fires) but the text is small/hidden or its content is wall-clock; 13 are moot (font already
  in the .pkg). Correctness-only (right typography in clocks/titles), not an SSIM gain — nothing to conserve under
  the 0-regression rule. Hypothesis closed. (The pack's fonts are SIL OFL / open-licensed; bundling for typography
  correctness is a separate packaging decision, out of scope here.)
- **MAPA-TECHO.md — created (the ceiling map).** Classified all 56 sub-target (burst<0.90) scenes by why they're
  below target. **Zero category-(a) real animation bugs**: every large still−burst gap is (b) firewall-dropped
  fire/ember particles, (c) non-determinism (wall-clock clock/day-night/audio), or (d) WE idle-drift/capture —
  lumora's animation is correct where it can be, so the burst metric finds no motion regression to fix. Remaining
  ceiling = firewall assets (LUTs/sprites) + non-determinism + capture artifacts.
- **Found 1 mislabeled oracle ref: `3585875739`** (still 0.29). Verified by eye: lumora renders a Miku close-up;
  the oracle frame is a different wallpaper (Azure/夜莺 sunset + promo-box). lumora is correct; the oracle frame is
  wrong → exclude from the metric (it deflates the burst mean by ~0.006).
- mips-per-texture (optional tail) NOT pursued: round-9 already showed global mips net +0.0011 with 3 regressions;
  per-texture would be marginal (~+0.001–0.002) and the two lead tasks resolved the round (refuted/mapped).

ROUND 10 result: no render change (FUENTES SSIM-neutral, 0 animation bugs to fix); deliverables = MAPA-TECHO.md +
the FUENTES measurement + the 3585875739 mislabel finding. Baseline unchanged at burst-avg 0.8094. CI green.

### ROUND 11 — VISUAL-parity campaign (PROMPT-MAC-PARIDAD): GAP 3 + GAP 2a landed; GAP 1/2b/4 ASSET-BLOCKED
New directive reframes the goal: SSIM hid whole missing effects; criterion is now DOUBLE (visual A/B vs
we-reference + burst-avg no-regression). Worked GAP 3 → GAP 1 → GAP 2 → GAP 4.
- **`c6f059a` GAP 3 — effect-path blend table corrected.** Applied the verified patch: `weBlendValue` was
  truncated at 15/mis-ordered, so transpiled effect shaders blended wrong (Screen=7 DARKENED, tint=30 washed,
  pulse=9 Screen-not-Add, filmgrain=12 HardLight-not-SoftLight). Rewrote to WE's canonical common_blending.h enum
  + 9 missing helpers. Visual A/B (tint 2109561442/2320743618) composes correctly. burst-avg 0.8094→0.8091: 4
  scenes up, 2 SSIM-only dips (3372027807 −0.039, 3430675494 −0.025) that are VISUALLY NEUTRAL (A/B-verified) —
  the old WRONG blend coincidentally scored higher (the exact 'SSIM hides effect errors' case). Kept (correct math).
- **`10eb602` GAP 2a — depthparallax restored.** It was force-dropped for mis-registration; root cause was a
  missing uniform. Supply `g_ParallaxPosition=[0.5,0.5]` (rest → zero displacement) + remove from the skip list.
  3426865175 +0.098, 3409595232 +0.084, 0 regressions, mean 0.8091→**0.8110** (recovers the GAP3 dip + more).
  Visual A/B (3426865175 Frieren): layer registers correctly. ★ clean win.
- **`516c892` GAP 4 — shared-asset VFS fallback for sprites (ready, no-op without the dir).** spriteTexture now
  tries `<LUMORA_SHARED_ASSETS_DIR>/materials/<name>.tex` before the procedural/skip branch. Gated → strict no-op
  by default.
- **⛔ CRITICAL BLOCKER — the delivered package has NO shared sprite/perlin assets.** Both zips
  (`lumora-update-paridad` + the 822 MB `lumora-sesion-desktop`) ship **only `we-shared-assets/materials/util/
  clouds_256.tex`** (+ fonts). The directive §2 ("todo está en disco") is FALSE for this package: `fire2.tex`,
  `perlin_256.tex`, `light_shafts_*`, `rosepetals`, `debris`, etc. are NOT present (they live in the owner's
  Windows WE install, inaccessible from the Mac). Setting `LUMORA_SHARED_ASSETS_DIR` to this incomplete pack even
  REGRESSES 2 scenes (clouds_256 replaces a better procedural fallback: 2611087662 −0.029). Therefore:
  **GAP 1 (fire2), GAP 2b (cloudmotion needs perlin_256), GAP 4 visual validation are ASSET-BLOCKED here** — the
  code paths are ready; they need the owner's full `…/wallpaper_engine/assets/` to validate. Not a firewall/effort
  issue — the files aren't on this machine.
- bloom (GAP 2 secondary): not pursued — round-9 already refuted the wider/multilevel bloom (overshoot) and
  CORRECCIONES lists it as not-a-priority.

ROUND 11 result: mean burst-avg **0.8110** (from 0.8094), 0 net regressions, GAP3+depthparallax visually verified,
GAP4 fallback ready. Remaining gaps (fire/cloudmotion/god-rays/petals) blocked on the owner's shared-asset install.

### ROUND 12 — assets UNBLOCKED: GAP 1 fire flipbook + GAP 2b cloudmotion landed (visual-A/B-driven)
The owner shipped the full `we-shared-assets` pack (229 .tex + 200 .tex-json incl. fire2/perlin_256/light_shafts/
petals/…) + a corrected oracle frame (3585875739 was mislabeled). Re-baseline vs the corrected oracle (env-unset):
**0.8171**. ⚠️ KEY: setting `LUMORA_SHARED_ASSETS_DIR` to the pack now LOADS real sprites, but they render wrong
until each gap's rendering is fixed (env-set with current code regressed the mean — fire2 sampled the whole atlas
= garbled). So the env is the FOUNDATION; each gap fix makes its family render correctly. Criterion is the
directive's DOUBLE: **visual A/B vs we-reference is the arbiter; SSIM only vetoes UNINTENDED regressions** — a
correct effect that isn't pixel-aligned LOWERS SSIM (directive: "no rebotes fuego por delta-SSIM").
- **`bbd3414` GAP 1 — spritesheet flipbook.** ParticleInstance/PInst gain a per-instance uvRect (atlas cell);
  simulateParticles picks the cell from each particle's life fraction; the .tex-json `spritesheetsequences`
  gives frames + the cols×rows grid. Default uvRect = content-crop, so NON-flipbook particles are byte-identical
  → **env-unset is a strict no-op (0.8171)**. Visual A/B (3115845558, env set): the blue "Wildfire" flames
  (fire2, 32-frame additive atlas) now APPEAR and animate vs we-reference — they were 100% absent. (SSIM on that
  scene dips −0.012 env-set because the flames aren't pixel-aligned — the exact 'SSIM hides/penalises a real
  effect' case; kept per the directive.)
- **`b221b73` GAP 2b — cloudmotion restored.** The shared `util/perlin_256` now loads (env), and effect aux
  samplers named perlin/clouds bind a new `.repeat` sampler (EffectInput.aux gains a repeatWrap flag → a 2nd
  EffectRenderer sampler) so the time-scrolled noise UV wraps instead of clamping. cloudmotion is un-dropped only
  when sharedAssetsDir is set (without the perlin it still mis-distorts → stays dropped → env-unset no-op). The
  repeat flag is scoped to perlin/clouds ONLY (NOT the procedural util/noise, which keeps foliagesway's phase /
  the env-unset 0.8171 no-op intact). Visual A/B (3435120596): the cloud band drifts (32% of pixels move
  t2→t8). Oracle env-set: **3545444802 0.859 → 0.908 (+0.0485)**, 3435120596 flat (day/night gap dominates).
- depthparallax (GAP 2a) landed in round 11; the GAP 4 sprite-VFS fallback (round 11) now actually loads the real
  sprites once the env points at the pack.
- **GAP 4 status (god-rays/light-shafts/localcontrast) — EFFECT-AUX garbling, deferred.** With the env set, the
  full env-set mean is 0.8141 (< env-unset 0.8171): the flipbook fixed the sheet-atlas particle sprites and
  cloudmotion is restored, but ~10 scenes still regress because their EFFECT aux now resolves to the real shared
  texture and lumora's effect renders it WRONG — e.g. 3576279017 (godrays+lightshafts) gets a dark smudge over the
  character (visual A/B = a LOSS, not a win), 2303021395 (localcontrast), 1469094526. These are effect-rendering
  bugs (the directive's old "a packaged shaft drawn straight is a hard streak ≠ WE" concern), NOT the particle
  path. They need per-effect rendering fixes (or a selective drop) before env-set is shippable; the particle
  sprites (petals/debris) load via the fallback. Documented for the next round.

ROUND 12 result: env-unset **0.8171** (strict no-op, gate-clean). GAP 1 fire flames + GAP 2b cloud drift +
GAP 2a depthparallax + GAP 3 blend all VISUALLY verified vs we-reference and committed (b221b73 HEAD). env-set is
the mode that shows the effects (3545444802 +0.0485 clouds, fire flames appear) — NOT yet net-clean because
god-rays/light-shafts/localcontrast render garbled with the real aux (per-effect work remains). The 4 core gap
families are done; GAP 4 effect-aux rendering is the open item.

### FASE 3/4 — assessed (round 1)
- **T3.1 copybackground**: blocked — needs the transpiler to emit a `v_ScreenCoord` varying it never emits (compose shaders would reference an undefined varying); validation scenes already ≥0.93. **Deferred (XL/blocked).**
- **T3.2 camerapath**: gated; static zoom would regress 3479521040 (already matches without it); only 3675966045 has real animation and it's dominated by fire/clock/grade. **Deferred.**
- **T3.3 particle operators**: would require the reference engine's particle math (firewall-restricted) and the gaps are position-at-capture-instant (SSIM-unfixable). **Deferred.**
- **T4.1 group/effectlayer**: effectlayer effects are grade/glitch/audio-reactive (firewall-blocked LUTs or correct no-ops). **Deferred.**

## ROUND 13 — GAP 4b investigated: premise refuted + the real env-set regression fixed

Target (from `GAP4b-EFECTOS-COMPUESTOS-REF.md`): god-rays/light-shafts/localcontrast supposedly compose their
real aux as a "dark smudge" env-set (~21 scenes, e.g. 3576279017, 2303021395). Investigated with the full
corrected oracle (862 MB pack, 96×3 frames) re-extracted to a stable dir.

**Renderer is deterministic.** Two identical env-unset parity runs → 0 scenes differ (max 0.0005), same
burst-avg 0.8110. So the gate is reliable and every per-scene number below is real, not run-noise. (Round 12's
per-scene claims were partly confounded by comparing across *different binaries*.)

**Suspect #1 (UV `.zw`) — REFUTED.** Dumped the real `godrays_combine.vert` from the pkg: it emits
`v_TexCoord = a_TexCoord.xyxy` (so `.zw == .xy`, the `.zw` half-texel offset is HLSL_SM30-only). The transpiler
reproduces this exactly (`out.v_TexCoord = in.a_TexCoord.xyxy;`). Rays are NOT sampled in a corner.

**god-rays/light-shafts/localcontrast — render CORRECTLY, no dark smudge.** Of all 24 scenes using these effects,
the shared-assets dir changes the render of *zero* of them at t≥2 (byte-identical env-set vs env-unset). 3576279017
differs only at **t=0**, and the diff is scattered **particles + a soft glow** appearing env-set (the GAP 4 sprite
fallback / lightshafts aux) — NOT a smudge. Visual A/B (3576279017, 2303021395) vs the oracle: both match well.
The premise does not reproduce at HEAD; no code change made there ("root-cause, don't assume").

**The real env-set regression was cloudmotion.** A full env-set vs env-unset parity diff showed the only large
mover is 3545444802: **0.8592 → 0.7529 (−0.106)**. Both cloudmotion scenes regress env-set (3435120596 −0.002),
none benefit. cloudmotion's overrides ARE applied correctly (amount 0.032, granularity 1.06, …, verified by a
debug dump) and the warp is correctly masked to the cloud band (characters stay sharp), but its perlin warp phase
doesn't align with WE's capture — the static (un-warped) clouds match the oracle's crispness, the warped ones
smear (visual A/B confirms). **Dropped cloudmotion** (revert R12's restore): 3545444802 env-set recovers
**0.7529 → 0.8575** (≈ env-unset 0.8592). Round 12's "+0.0485 clean win" was a measurement artifact.

**Remaining env-set delta (−0.0034 vs env-unset) is the GAP 1 fire / GAP 4 particle "correct-but-unaligned"
content** — embers/particles/flames the oracle also has but at different positions (e.g. 1469094526 −0.040 = ember
positions; visual A/B = a match, not garbling). Kept per the directive's "no rebotes fuego por delta-SSIM" rule.

ROUND 13 result: env-unset **0.8110** (unchanged — cloudmotion was already dropped there). env-set's worst-case
regression (cloudmotion 3545444802 −0.106) is eliminated; the remaining env-set content is correct-but-unaligned
particles/fire (kept by design). The GAP 4b "effect-aux garbling" premise is closed as refuted. Dev tooling added:
`WEImporterChecks dump` / `texpng` (inspect packaged shaders + loose .tex tiles).

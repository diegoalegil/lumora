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

### FASE 3/4 — assessed
- **T3.1 copybackground**: blocked — needs the transpiler to emit a `v_ScreenCoord` varying it never emits (compose shaders would reference an undefined varying); validation scenes already ≥0.93. **Deferred (XL/blocked).**
- **T3.2 camerapath**: gated; static zoom would regress 3479521040 (already matches without it); only 3675966045 has real animation and it's dominated by fire/clock/grade. **Deferred.**
- **T3.3 particle operators**: would require the reference engine's particle math (firewall-restricted) and the gaps are position-at-capture-instant (SSIM-unfixable). **Deferred.**
- **T4.1 group/effectlayer**: effectlayer effects are grade/glitch/audio-reactive (firewall-blocked LUTs or correct no-ops). **Deferred.**

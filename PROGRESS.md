# PROGRESS — autopilot fidelity vs we-reference (taskbar-cropped, BURST-aware gate)

## ⛔ ROUND 14 — SAME-BINARY MEASUREMENT PROTOCOL (the golden rule — follow for EVERY delta)
The renderer is DETERMINISTIC (two identical runs = 0 byte diff). So every delta MUST be measured
baseline-AND-after with the SAME measurement run, never against a number from an older build:
1. Build ONE fresh binary.
2. Measure condition A with it (env-unset, or "before-change").
3. Measure condition B with it (env-set, or a SECOND binary built THIS run that has the change).
4. Valid delta = B−A from this run. Annotate every number with the binary md5 / commit.
5. Any figure not attributable to a same-binary run = treat as nonexistent, re-measure.
Cross-binary comparison fabricates false deltas (it muddied R11/R12 per-scene claims).

## ROUND 14 — P1 CANONICAL BASELINE (full oracle 96×3, crop=48 default)
Same-binary master table in [`R14-BASELINE.tsv`](R14-BASELINE.tsv) (96 scenes: unset/set/delta).
- **CANONICAL v2 @ HEAD `1a92d2f` (+overbright), CORRECTED 3585875739 oracle:**
  **env-unset 0.8177 · env-set 0.8144 · delta −0.0034** · ≥0.80 56/56 · ≥0.90 40/40.
- ⚠️ **Oracle fix:** the 862MB-zip `we-reference/3585875739` is the OLD MISLABEL (silver-haired fire scene);
  the CORRECT frame (Miku close-up, matches lumora) ships in the small extract's `we-reference/3585875739{,_t1,_t2}`.
  Overlaid it → 3585875739 0.31→**0.889**, lifting the mean +0.0067. Always use the small-extract 3585875739.
- Pre-correction v1 (binary `6dbe9fa`, mislabeled 3585875739): env-unset 0.8110 / env-set 0.8076 — those
  reproduced the R12 figures exactly same-binary (valid, NOT artifacts), but were depressed by the mislabel.
  `0.8094 @ d4c671f` is the older *docs* baseline (different oracle/crop), historical only. v2 is canonical.
- env-set: 41 scenes down / 10 up. The net −0.0034 is GAP1-fire / GAP4-particle correct-but-pixel-unaligned
  content (embers/flames at a different stochastic phase than the captured frame) — CONSERVED per §4.4, not a bug.
- **depthparallax — re-verified same-binary = REAL WIN, kept.** active vs dropped (both built this run):
  3426865175 0.8027 vs 0.7051 (+0.098), 3409595232 0.7817 vs 0.6983 (+0.083), 3669680904 +0.002, others flat,
  0 regression. The R11 "+0.098/+0.083" was NOT a cross-binary artifact.
- **GAP 3 blend table — re-verified same-binary = REAL WIN, kept.** ON vs OFF (pre-c6f059a prelude, built this
  run): 5 up (2381855517 +0.016, 3576279017 +0.0095, 3497714247/2109561442 +0.006, 2320743618 +0.004) and 2
  SSIM-only dips (3372027807 −0.039, 3430675494 −0.025) whose A/B vs oracle CONFIRMS ON is correct (Itachi red
  atmosphere matches; Supra grade/color matches minus the non-det clock) — old wrong blend coincidentally scored
  higher. Correct-by-spec (WE common_blending.h enum); kept.
- **`faithfulnessDropEffects = ["cloudmotion"]`** (read from source @ SceneRenderer.swift). cloudmotion stays
  dropped (R13, same-binary −0.106). depthparallax is NOT in the list (wired + verified above).

The gate now scores each scene against its still + `_t1`/`_t2` bursts (best phase per frame, averaged),
so animation/phase is covered, not just frame 0. `LUMORA_PARITY_STILL_ONLY=1` gives the old single-still metric.

**Burst-avg mean SSIM 0.8094** (still-only 0.8155) · ≥0.80 54/96 · ≥0.90 40/96 @ HEAD.

D (wrap REPEAT by ClampUVs) measured-NEUTRAL + reverted; E (mipmaps) measured (3 regressions >0.005) + reverted.

**Round 13 (GAP 4b investigated):** the god-rays/light-shafts/localcontrast "dark smudge" premise is **REFUTED** —
those effects are byte-identical env-set vs env-unset at t≥2 and render correctly vs the oracle (the only env-set
change is GAP 4 particles + a soft glow at t=0, not a smudge). Suspect #1 (`v_TexCoord.zw`) refuted: the transpiler
emits `a_TexCoord.xyxy` correctly. The renderer is **deterministic** (two env-unset runs identical → the gate is
reliable). The real env-set regression was **cloudmotion** (3545444802 0.8592→0.7529, −0.106; both its scenes
regress, none benefit) — **dropped it** (revert R12), 3545444802 recovers to 0.8575 (≈ env-unset). R12's "+0.0485"
was a measurement artifact. Remaining env-set −0.0034 vs env-unset is GAP 1 fire / GAP 4 particle correct-but-
unaligned content (kept per "no rebotes fuego por delta-SSIM"). See CHANGELOG ROUND 13.

**Round 12 (assets unblocked, visual-A/B):** full we-shared-assets pack arrived; corrected oracle (3585875739),
re-baseline env-unset **0.8171**. Landed (each env-gated → env-unset strict no-op 0.8171, visual-A/B-verified vs
we-reference): **GAP 1 fire flipbook** (`bbd3414` — blue Wildfire flames appear+animate on 3115845558/3675966045,
were 100% absent), **GAP 2b cloudmotion** (`b221b73` — clouds drift; 3545444802 env-set +0.0485). Set
`LUMORA_SHARED_ASSETS_DIR` to the pack to activate. ⚠️ env-set net 0.8141 (< 0.8171) because god-rays/light-shafts/
localcontrast EFFECTS render garbled with the real aux (e.g. 3576279017 dark smudge) — per-effect rendering work,
the open GAP 4 item. Fire SSIM dips env-set (flames not pixel-aligned) but is a visual win (kept per directive).
See CHANGELOG ROUND 12.

**Round 11 (visual-parity, PROMPT-MAC-PARIDAD):** GAP 3 (effect blend table → WE-canonical, `c6f059a`) +
GAP 2a (depthparallax `g_ParallaxPosition` fix, `10eb602`: 3426865175 +0.098, 3409595232 +0.084) landed,
visually A/B-verified, **mean burst-avg 0.8094 → 0.8110**, 0 net regressions. GAP 4 sprite shared-asset fallback
ready (`516c892`, no-op without the dir). ⛔ **GAP 1 (fire2), GAP 2b (cloudmotion/perlin_256), GAP 4 visual** are
ASSET-BLOCKED: the package ships only `util/clouds_256.tex` — the fire/perlin/light-shaft/petal/debris sprites
are NOT in it (they're in the owner's Windows WE install). Need that install pointed to by
`LUMORA_SHARED_ASSETS_DIR` to finish those gaps. See CHANGELOG ROUND 11 + MAPA-TECHO.

**Round 10:** FUENTES (shared-font fallback) **refuted as an SSIM lever** — A/B over the 21 candidates moved 0
scenes >0.005 (max +0.0008); correctness-only. **MAPA-TECHO.md** classifies every sub-target scene: **0 real
animation bugs** — ceiling is firewall assets + non-determinism + capture artifacts. Found 1 mislabeled oracle
ref **`3585875739`** (lumora correct, oracle frame is a different wallpaper) — excluding it lifts the true burst
mean ~+0.006. See `MAPA-TECHO.md`.

| id | burst SSIM | still SSIM | estado |
|---|---|---|---|
| 3675966045 | 0.2683 | 0.2699 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3585875739 | 0.3054 | 0.2909 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2423807815 | 0.3471 | 0.3549 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3660962877 | 0.3917 | 0.3823 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2381855517 | 0.4729 | 0.4824 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3390491312 | 0.5010 | 0.5045 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3435120596 | 0.5181 | 0.5195 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3372027807 | 0.5749 | 0.5850 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3355037946 | 0.5751 | 0.5704 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3627327015 | 0.5770 | 0.5784 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2238042939 | 0.5901 | 0.9971 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2479422222 | 0.5913 | 0.5832 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3497714247 | 0.5999 | 0.5740 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3319713168 | 0.6191 | 0.5985 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3461353800 | 0.6369 | 0.6204 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2817222811 | 0.6380 | 0.6372 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3115845558 | 0.6382 | 0.6237 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3577990983 | 0.6514 | 0.7381 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3324136043 | 0.6546 | 0.6562 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 916545283 | 0.6604 | 0.6690 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2872509253 | 0.6737 | 0.6753 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3265802028 | 0.6759 | 0.6778 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 1683040946 | 0.6880 | 0.9711 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3409595232 | 0.6982 | 0.6670 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3426865175 | 0.7051 | 0.7105 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3470764447 | 0.7119 | 0.7135 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3362719513 | 0.7142 | 0.7134 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3276911872 | 0.7215 | 0.7337 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3326873240 | 0.7231 | 0.7321 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3355791741 | 0.7249 | 0.6672 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3447271084 | 0.7291 | 0.7350 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3436033033 | 0.7311 | 0.7013 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3565328165 | 0.7334 | 0.7614 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3430675494 | 0.7396 | 0.7339 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3404976219 | 0.7424 | 0.7827 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3013169753 | 0.7521 | 0.7157 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3669680904 | 0.7537 | 0.7740 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3615821365 | 0.7702 | 0.8422 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3438420195 | 0.7784 | 0.7919 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2487757810 | 0.7878 | 0.7630 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2996283606 | 0.7923 | 0.7861 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3528564892 | 0.7959 | 0.6872 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3195212886 | 0.8184 | 0.8179 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3418060002 | 0.8501 | 0.8460 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 1264202805 | 0.8516 | 0.8194 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3353892691 | 0.8535 | 0.8637 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3291581513 | 0.8547 | 0.8544 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3545444802 | 0.8591 | 0.8619 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3646049140 | 0.8640 | 0.8775 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3576279017 | 0.8660 | 0.8551 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3479521040 | 0.8671 | 0.8742 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 1588298589 | 0.8673 | 0.8720 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 1433564192 | 0.8755 | 0.8744 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 1229038692 | 0.8869 | 0.9098 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2223651672 | 0.8935 | 0.8993 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 3200980645 | 0.8959 | 0.8968 | blocked (firewall LUT / wall-clock / text / animation-phase) |
| 2636878454 | 0.9039 | 0.9006 | in-target |
| 3198624623 | 0.9075 | 0.9201 | in-target |
| 2611087662 | 0.9205 | 0.9033 | in-target |
| 2064316482 | 0.9264 | 0.9304 | in-target |
| 2892812454 | 0.9379 | 0.9010 | in-target |
| 2303021395 | 0.9386 | 0.9397 | in-target |
| 2583077343 | 0.9395 | 0.9308 | in-target |
| 2829689820 | 0.9410 | 0.9336 | in-target |
| 2140101288 | 0.9441 | 0.9365 | in-target |
| 2780446545 | 0.9528 | 0.9429 | in-target |
| 2820544627 | 0.9531 | 0.9604 | in-target |
| 3239767814 | 0.9531 | 0.9806 | in-target |
| 1469094526 | 0.9598 | 0.9561 | in-target |
| 1431235492 | 0.9621 | 0.9496 | in-target |
| 2111201226 | 0.9645 | 0.9616 | in-target |
| 1773105076 | 0.9667 | 0.9688 | in-target |
| 3040327022 | 0.9677 | 0.9652 | in-target |
| 3352698943 | 0.9693 | 0.9691 | in-target |
| 2609314022 | 0.9733 | 0.9739 | in-target |
| 2363806159 | 0.9741 | 0.9741 | in-target |
| 3482079065 | 0.9754 | 0.9749 | in-target |
| 2420441089 | 0.9765 | 0.9770 | in-target |
| 2114035295 | 0.9777 | 0.9777 | in-target |
| 2109561442 | 0.9781 | 0.9815 | in-target |
| 3624053922 | 0.9788 | 0.9813 | in-target |
| 947540551 | 0.9789 | 0.9795 | in-target |
| 3330384164 | 0.9799 | 0.9798 | in-target |
| 2186612524 | 0.9810 | 0.9816 | in-target |
| 3350974549 | 0.9826 | 0.9808 | in-target |
| 2190291768 | 0.9839 | 0.9851 | in-target |
| 2320743618 | 0.9841 | 0.9870 | in-target |
| 3334481827 | 0.9849 | 0.9855 | in-target |
| 1646847449 | 0.9869 | 0.9878 | in-target |
| 2219540918 | 0.9879 | 0.9883 | in-target |
| 2468167360 | 0.9884 | 0.9892 | in-target |
| 3258032485 | 0.9897 | 0.9860 | in-target |
| 1537139001 | 0.9919 | 0.9919 | in-target |
| 2284309190 | 0.9927 | 0.9925 | in-target |
| 2978610140 | 0.9931 | 0.9931 | in-target |
| 3031418765 | 0.9950 | 0.9950 | in-target |

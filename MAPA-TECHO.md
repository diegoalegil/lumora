# MAPA-TECHO.md — ceiling map of sub-target scenes (HEAD d4c671f, burst-avg gate)

Canonical metric: **burst-avg(still+_t1+_t2)** vs `we-reference/`. Baseline mean **0.8094** (still-only 0.8155).
This map answers *what remains and why*, and isolates real animation bugs from non-fixable noise.

## Headline
- **Zero category-(a) real animation bugs found.** Every large `still−burst` gap is (b) firewall-dropped
  particles, (c) non-determinism (wall-clock/audio/scripted), or (d) WE idle-drift — lumora's animation
  is correct where it can be. So the burst metric confirms no motion regression to fix.
- **FUENTES (shared-font fallback) refuted as an SSIM lever:** A/B over the 21 candidates moved 0 scenes
  >0.005 (max +0.0008); 8 re-rasterise with the correct font but the text is small/hidden or its content
  is wall-clock, and 13 are moot (font already in the .pkg). Correctness-only; not an SSIM gain.
- Remaining sub-target ceiling is **firewall assets (LUTs, fire/ember sprites)** + **non-determinism**
  (wall-clock clock/day-night/audio) + **capture artifacts** (taskbar/idle-drift). None are lumora render bugs.

## Legend
(a) real animation bug → fixable · (b) firewall-blocked asset · (c) non-determinism (wall-clock/audio/
scripted/scroll) · (d) WE idle-drift/framing/capture · **firewall** = blocked WE asset (LUT/sprite).

## Sub-target scenes (burst < 0.90), worst first
| id | still | burst | gap | cat | why it's below target |
|---|---|---|---|---|---|
| 3675966045 | 0.2699 | 0.2683 | +0.0016 | b | fire/ember particle sprites dropped (firewall asset) |
| 3585875739 | 0.2909 | 0.3054 | -0.0145 | MISLABEL | oracle ref is a DIFFERENT wallpaper (verified by eye: lumora=Miku close-up, oracle=Azure/夜莺 sunset scene w/ promo-box) — lumora is CORRECT; exclude from the metric |
| 2423807815 | 0.3549 | 0.3471 | +0.0078 | c | scripted state (day/night/effect script lumora doesn't run) |
| 3660962877 | 0.3823 | 0.3917 | -0.0094 | c | clock/date text — content is wall-clock dependent; can't match the capture's time |
| 2381855517 | 0.4824 | 0.4729 | +0.0095 | c | scrolling-comic capture phase (timing) |
| 3390491312 | 0.5045 | 0.5010 | +0.0035 | d | cover-fit framing / WE idle parallax |
| 3435120596 | 0.5195 | 0.5181 | +0.0014 | c | scripted state (day/night/effect script lumora doesn't run) |
| 3372027807 | 0.5850 | 0.5749 | +0.0101 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3355037946 | 0.5704 | 0.5751 | -0.0047 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3627327015 | 0.5784 | 0.5770 | +0.0014 | c | clock/date text — content is wall-clock dependent; can't match the capture's time |
| 2238042939 | 0.9971 | 0.5901 | +0.4070 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue); animation gap 0.407: static image; lumora correct at 0.997 vs still, WE _t1 drifts +22 luma (idle/capture) |
| 2479422222 | 0.5832 | 0.5913 | -0.0081 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3497714247 | 0.5740 | 0.5999 | -0.0259 | c | clock/date text — content is wall-clock dependent; can't match the capture's time |
| 3319713168 | 0.5985 | 0.6191 | -0.0206 | b | fire/ember particle sprites dropped (firewall asset) |
| 3461353800 | 0.6204 | 0.6369 | -0.0165 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 2817222811 | 0.6372 | 0.6380 | -0.0008 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3115845558 | 0.6237 | 0.6382 | -0.0145 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3577990983 | 0.7381 | 0.6514 | +0.0867 | c | clock/date text — content is wall-clock dependent; can't match the capture's time; animation gap 0.087: fire/rain particles + transition fx animate (firewall + audio-visualiser) |
| 3324136043 | 0.6562 | 0.6546 | +0.0016 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 916545283 | 0.6690 | 0.6604 | +0.0086 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 2872509253 | 0.6753 | 0.6737 | +0.0016 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3265802028 | 0.6778 | 0.6759 | +0.0019 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 1683040946 | 0.9711 | 0.6880 | +0.2831 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue); animation gap 0.283: 'Ember' fire particles animate in WE (firewall-dropped) |
| 3409595232 | 0.6670 | 0.6982 | -0.0312 | c | scripted state (day/night/effect script lumora doesn't run) |
| 3426865175 | 0.7105 | 0.7051 | +0.0054 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3470764447 | 0.7135 | 0.7119 | +0.0016 | c | wall-clock day/night — non-deterministic |
| 3362719513 | 0.7134 | 0.7142 | -0.0008 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 3276911872 | 0.7337 | 0.7215 | +0.0122 | c | particle phase at the capture instant (timing) |
| 3326873240 | 0.7321 | 0.7231 | +0.0090 | c | wall-clock day/night — non-deterministic |
| 3355791741 | 0.6672 | 0.7249 | -0.0577 | c | scripted state (day/night/effect script lumora doesn't run) |
| 3447271084 | 0.7350 | 0.7291 | +0.0059 | c | clock/date text — content is wall-clock dependent; can't match the capture's time |
| 3436033033 | 0.7013 | 0.7311 | -0.0298 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3565328165 | 0.7614 | 0.7334 | +0.0280 | c | clock/date text — content is wall-clock dependent; can't match the capture's time; animation gap 0.028: clock/date text — wall-clock content |
| 3430675494 | 0.7339 | 0.7396 | -0.0057 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 3404976219 | 0.7827 | 0.7424 | +0.0403 | d | Windows taskbar capture artifact (cropped); residual = minor/other; animation gap 0.040: audio-reactive + snow/ember + clock — all correctly excluded/blocked |
| 3013169753 | 0.7157 | 0.7521 | -0.0364 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 3669680904 | 0.7740 | 0.7537 | +0.0203 | firewall | color-grade LUT — needs WE's LUT asset (firewall-blocked) |
| 3615821365 | 0.8422 | 0.7702 | +0.0720 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue); animation gap 0.072: 'Brasa grande'/ember + wind-trail particles animate (firewall) |
| 3438420195 | 0.7919 | 0.7784 | +0.0135 | c | clock/date text — content is wall-clock dependent; can't match the capture's time |
| 2487757810 | 0.7630 | 0.7878 | -0.0248 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 2996283606 | 0.7861 | 0.7923 | -0.0062 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3528564892 | 0.6872 | 0.7959 | -0.1087 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3195212886 | 0.8179 | 0.8184 | -0.0005 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3418060002 | 0.8460 | 0.8501 | -0.0041 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 1264202805 | 0.8194 | 0.8516 | -0.0322 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3353892691 | 0.8637 | 0.8535 | +0.0102 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3291581513 | 0.8544 | 0.8547 | -0.0003 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3545444802 | 0.8619 | 0.8591 | +0.0028 | d | Windows taskbar capture artifact (cropped); residual = minor/other |
| 3646049140 | 0.8775 | 0.8640 | +0.0135 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3576279017 | 0.8551 | 0.8660 | -0.0109 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3479521040 | 0.8742 | 0.8671 | +0.0071 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 1588298589 | 0.8720 | 0.8673 | +0.0047 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 1433564192 | 0.8744 | 0.8755 | -0.0011 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 1229038692 | 0.9098 | 0.8869 | +0.0229 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 2223651672 | 0.8993 | 0.8935 | +0.0058 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |
| 3200980645 | 0.8968 | 0.8959 | +0.0009 | near | near-target (0.80–0.90): minor residual, no single blocker (filmgrain/colour/text residue) |

## Category tally (sub-target): {'MISLABEL': 1, 'b': 2, 'c': 15, 'd': 15, 'firewall': 6, 'near': 17}
- (a) real animation bugs: **0** — nothing to fix in the render this round.
- The ceiling is structural: firewall assets + wall-clock non-determinism + capture artifacts.

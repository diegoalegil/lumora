# CHANGELOG — autopilot fidelity run (vs we-reference clean oracle)

Arbiter: SSIM vs `we-reference/<id>.png` (best-matching phase), 96 scenes. Keep a change only if it
raises target scenes and regresses nothing >0.005; otherwise revert. Commits authored by the owner.

## Baseline @ `fa3e8f3`
- Clean re-captured oracle (96×3 frames, playlist-off — the 6 prior mislabels are fixed).
- Mean SSIM **0.7958**, ≥0.80 **58/96**, ≥0.90 **38/96**.
- PROGRESS.md generated with per-scene objective = max(0.90, baseline).

## Entries
(one per commit, newest last)

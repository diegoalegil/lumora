# PROGRESS — autopilot fidelity vs we-reference (taskbar-cropped gate)

Gate now crops the bottom 48px by default (Windows taskbar baked into ~32 captures). Baseline @ `fa3e8f3`+crop.
Mean SSIM **0.8117** · ≥0.80 **58/96** · ≥0.90 **43/96**. Objetivo = max(0.90, baseline).

`estado`: in-target (≥0.90) · or the diagnosed blocking cause (firewall LUT / day-night / scripted / fire-aux / scroll / particle-phase — none lumora-fixable) · near-target (<0.90, no single blocking cause).
⚠️ NOTE: the we-reference oracle was removed from disk by the environment between sessions; these are the last real-oracle (crop) numbers. Re-extract the package to resume live measurement.

| id | SSIM (crop) | objetivo | estado | commit |
|---|---|---|---|---|
| 3675966045 | 0.2603 | 0.9000 | fire-aux-dropped | fa3e8f3 |
| 2423807815 | 0.3590 | 0.9000 | scripted-state | fa3e8f3 |
| 3660962877 | 0.3753 | 0.9000 | missing-text-clock | fa3e8f3 |
| 3430675494 | 0.4130 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 3390491312 | 0.4907 | 0.9000 | framing-parallax | fa3e8f3 |
| 3265802028 | 0.5074 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 2381855517 | 0.5102 | 0.9000 | scroll-phase | fa3e8f3 |
| 3435120596 | 0.5158 | 0.9000 | scripted-state | fa3e8f3 |
| 3470764447 | 0.5181 | 0.9000 | day-night | fa3e8f3 |
| 3326873240 | 0.5416 | 0.9000 | day-night | fa3e8f3 |
| 3355037946 | 0.5676 | 0.9000 | near-target | fa3e8f3 |
| 3627327015 | 0.5758 | 0.9000 | missing-text-clock | fa3e8f3 |
| 2479422222 | 0.5818 | 0.9000 | near-target | fa3e8f3 |
| 3355791741 | 0.5932 | 0.9000 | scripted-state | fa3e8f3 |
| 3497714247 | 0.5934 | 0.9000 | missing-text-clock | fa3e8f3 |
| 3372027807 | 0.5947 | 0.9000 | near-target | fa3e8f3 |
| 3319713168 | 0.6090 | 0.9000 | fire-aux-dropped | fa3e8f3 |
| 3565328165 | 0.6362 | 0.9000 | missing-text-clock | fa3e8f3 |
| 2817222811 | 0.6553 | 0.9000 | near-target | fa3e8f3 |
| 3324136043 | 0.6589 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 3409595232 | 0.6610 | 0.9000 | scripted-state | fa3e8f3 |
| 3461353800 | 0.6619 | 0.9000 | near-target | fa3e8f3 |
| 2872509253 | 0.6648 | 0.9000 | near-target | fa3e8f3 |
| 916545283 | 0.6688 | 0.9000 | near-target | fa3e8f3 |
| 3426865175 | 0.6781 | 0.9000 | near-target | fa3e8f3 |
| 3115845558 | 0.6882 | 0.9000 | near-target | fa3e8f3 |
| 3528564892 | 0.6887 | 0.9000 | near-target | fa3e8f3 |
| 3436033033 | 0.6994 | 0.9000 | near-target | fa3e8f3 |
| 3362719513 | 0.7127 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 3447271084 | 0.7209 | 0.9000 | missing-text-clock | fa3e8f3 |
| 3577990983 | 0.7367 | 0.9000 | missing-text-clock | fa3e8f3 |
| 3276911872 | 0.7395 | 0.9000 | particle-phase | fa3e8f3 |
| 3013169753 | 0.7422 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 3438420195 | 0.7522 | 0.9000 | missing-text-clock | fa3e8f3 |
| 3545444802 | 0.7532 | 0.9000 | near-target | fa3e8f3 |
| 2487757810 | 0.7568 | 0.9000 | near-target | fa3e8f3 |
| 3669680904 | 0.7671 | 0.9000 | color-grade-LUT | fa3e8f3 |
| 3404976219 | 0.7826 | 0.9000 | near-target | fa3e8f3 |
| 3195212886 | 0.8140 | 0.9000 | near-target | fa3e8f3 |
| 3615821365 | 0.8439 | 0.9000 | near-target | fa3e8f3 |
| 3418060002 | 0.8461 | 0.9000 | near-target | fa3e8f3 |
| 3576279017 | 0.8527 | 0.9000 | near-target | fa3e8f3 |
| 3291581513 | 0.8558 | 0.9000 | near-target | fa3e8f3 |
| 1264202805 | 0.8590 | 0.9000 | near-target | fa3e8f3 |
| 3353892691 | 0.8638 | 0.9000 | near-target | fa3e8f3 |
| 2996283606 | 0.8646 | 0.9000 | near-target | fa3e8f3 |
| 1588298589 | 0.8669 | 0.9000 | near-target | fa3e8f3 |
| 3479521040 | 0.8737 | 0.9000 | near-target | fa3e8f3 |
| 1469094526 | 0.8767 | 0.9000 | near-target | fa3e8f3 |
| 3646049140 | 0.8770 | 0.9000 | near-target | fa3e8f3 |
| 1433564192 | 0.8777 | 0.9000 | near-target | fa3e8f3 |
| 2892812454 | 0.8974 | 0.9000 | near-target | fa3e8f3 |
| 3200980645 | 0.8987 | 0.9000 | near-target | fa3e8f3 |
| 2223651672 | 0.9017 | 0.9017 | in-target | fa3e8f3 |
| 2636878454 | 0.9078 | 0.9078 | in-target | fa3e8f3 |
| 1229038692 | 0.9125 | 0.9125 | in-target | fa3e8f3 |
| 3198624623 | 0.9183 | 0.9183 | in-target | fa3e8f3 |
| 2829689820 | 0.9193 | 0.9193 | in-target | fa3e8f3 |
| 2064316482 | 0.9226 | 0.9226 | in-target | fa3e8f3 |
| 2140101288 | 0.9327 | 0.9327 | in-target | fa3e8f3 |
| 2583077343 | 0.9376 | 0.9376 | in-target | fa3e8f3 |
| 2303021395 | 0.9395 | 0.9395 | in-target | fa3e8f3 |
| 3585875739 | 0.9423 | 0.9423 | in-target | fa3e8f3 |
| 2780446545 | 0.9426 | 0.9426 | in-target | fa3e8f3 |
| 1431235492 | 0.9512 | 0.9512 | in-target | fa3e8f3 |
| 1773105076 | 0.9567 | 0.9567 | in-target | fa3e8f3 |
| 2611087662 | 0.9572 | 0.9572 | in-target | fa3e8f3 |
| 2111201226 | 0.9654 | 0.9654 | in-target | fa3e8f3 |
| 3352698943 | 0.9661 | 0.9661 | in-target | fa3e8f3 |
| 3040327022 | 0.9728 | 0.9728 | in-target | fa3e8f3 |
| 3482079065 | 0.9746 | 0.9746 | in-target | fa3e8f3 |
| 2320743618 | 0.9756 | 0.9756 | in-target | fa3e8f3 |
| 2363806159 | 0.9756 | 0.9756 | in-target | fa3e8f3 |
| 2420441089 | 0.9772 | 0.9772 | in-target | fa3e8f3 |
| 1683040946 | 0.9773 | 0.9773 | in-target | fa3e8f3 |
| 2114035295 | 0.9782 | 0.9782 | in-target | fa3e8f3 |
| 2820544627 | 0.9788 | 0.9788 | in-target | fa3e8f3 |
| 3330384164 | 0.9797 | 0.9797 | in-target | fa3e8f3 |
| 947540551 | 0.9800 | 0.9800 | in-target | fa3e8f3 |
| 3350974549 | 0.9803 | 0.9803 | in-target | fa3e8f3 |
| 3239767814 | 0.9806 | 0.9806 | in-target | fa3e8f3 |
| 2609314022 | 0.9808 | 0.9808 | in-target | fa3e8f3 |
| 2109561442 | 0.9810 | 0.9810 | in-target | fa3e8f3 |
| 3624053922 | 0.9814 | 0.9814 | in-target | fa3e8f3 |
| 2186612524 | 0.9820 | 0.9820 | in-target | fa3e8f3 |
| 2190291768 | 0.9840 | 0.9840 | in-target | fa3e8f3 |
| 3334481827 | 0.9856 | 0.9856 | in-target | fa3e8f3 |
| 3258032485 | 0.9874 | 0.9874 | in-target | fa3e8f3 |
| 1646847449 | 0.9879 | 0.9879 | in-target | fa3e8f3 |
| 2468167360 | 0.9892 | 0.9892 | in-target | fa3e8f3 |
| 2219540918 | 0.9893 | 0.9893 | in-target | fa3e8f3 |
| 1537139001 | 0.9919 | 0.9919 | in-target | fa3e8f3 |
| 2284309190 | 0.9930 | 0.9930 | in-target | fa3e8f3 |
| 2978610140 | 0.9932 | 0.9932 | in-target | fa3e8f3 |
| 3031418765 | 0.9950 | 0.9950 | in-target | fa3e8f3 |
| 2238042939 | 0.9971 | 0.9971 | in-target | fa3e8f3 |

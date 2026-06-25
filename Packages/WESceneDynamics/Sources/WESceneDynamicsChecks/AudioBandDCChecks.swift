// SPDX-License-Identifier: MIT
// Provenance: clean-room. Regression check that the packed-FFT Nyquist term (carried in imagp[0]) is no longer
// conflated into bin 0, where the lowest sub-bin bands interpolate — so ~24 kHz energy can't leak into the bass.
import Foundation
import WESceneDynamics

func runAudioBandDCChecks() {
    Check.section("AudioBandMapper Nyquist isolation")

    guard let mapper = AudioBandMapper(fftSize: 1024) else {
        Check.that("mapper builds", false); return
    }
    let n = 1024

    // A pure Nyquist tone (alternating ±1) is the highest representable frequency; its energy lands in the
    // packed real-FFT's bin-0 imaginary slot. After cleaning bin 0 to pure DC, it must NOT light the bass.
    let nyquist = (0 ..< n).map { Float($0 % 2 == 0 ? 1 : -1) }
    let nyqBands = mapper.bands(from: nyquist, count: 64)
    Check.that("a Nyquist tone leaves the lowest bass bands dark", (nyqBands.prefix(6).max() ?? 1) < 0.15)

    // Sanity: a genuine low tone still registers in a low band (cleaning bin 0 didn't deafen the bass).
    let sr: Float = 48_000, toneHz: Float = 90
    let bass = (0 ..< n).map { sin(2 * Float.pi * toneHz * Float($0) / sr) }
    let bassBands = mapper.bands(from: bass, count: 64)
    Check.that("a real low tone still lights a low band", (bassBands.prefix(16).max() ?? 0) > 0.1)
}

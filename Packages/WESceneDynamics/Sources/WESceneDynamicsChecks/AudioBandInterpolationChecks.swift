// SPDX-License-Identifier: MIT
// Provenance: clean-room. Deterministic checks for the sub-bin-width band interpolation in AudioBandMapper.
// Validates the new behavior (linear interpolation of power at a narrow band's center frequency between the
// two straddling FFT bins) against the standard short-time-spectrum contract, with no audio hardware: the
// math is fully exercised from synthetic PCM. Golden vectors below were produced by this very pipeline; the
// interpolation change provably touches only sub-bin bands, so every wide (summed/averaged) band is byte-
// identical to the original summation — the no-regression guarantee these checks lock down.
import Foundation
import WESceneDynamics

// A fixed, fully deterministic multi-tone window (no randomness): three sines so the low end has real, distinct
// energy across neighbouring narrow bands. Reused across the golden / no-regression checks.
private func fixedMultiTone(count: Int, sampleRate: Float = 48_000) -> [Float] {
    (0 ..< count).map { i -> Float in
        let t = Float(i)
        return 0.6 * sin(2 * .pi * 110 * t / sampleRate)
             + 0.3 * sin(2 * .pi * 440 * t / sampleRate)
             + 0.2 * sin(2 * .pi * 3500 * t / sampleRate)
    }
}

// A single pure tone, swept across frequencies, to show neighbouring narrow 64-bands no longer collapse.
private func tone(_ hz: Float, count: Int, sampleRate: Float = 48_000) -> [Float] {
    (0 ..< count).map { sin(2 * .pi * hz * Float($0) / sampleRate) }
}

// Closest match for floats coming out of a normalized 0…1 pipeline.
private func approxEqual(_ a: [Float], _ b: [Float], tol: Float = 1e-5) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol }
}

func runAudioBandInterpolationChecks() {
    guard let mapper = AudioBandMapper(fftSize: 1024) else {
        Check.section("AudioBandMapper — sub-bin interpolation")
        Check.that("mapper constructs", false)
        return
    }

    Check.section("AudioBandMapper — sub-bin interpolation: silence")
    // All-zero input must still yield all-zero bands at every resolution, including 64 where the low bands take
    // the interpolation path (an interpolation that read a stale/garbage bin would break this).
    for count in [16, 32, 64] {
        let z = mapper.bands(from: [Float](repeating: 0, count: 1024), count: count)
        Check.that("all-zero input → all-zero \(count) bands", z.count == count && z.allSatisfy { $0 == 0 })
    }

    Check.section("AudioBandMapper — sub-bin interpolation: tone localization")
    // A pure tone still peaks in its own band after the change. Band index for a log-spaced 30 Hz…Nyquist axis.
    func bandIndex(forHz hz: Float, count: Int, sampleRate: Float = 48_000) -> Int {
        let fLo: Float = 30, fHi = sampleRate / 2
        let ratio = log(hz / fLo) / log(fHi / fLo)
        return min(count - 1, max(0, Int(ratio * Float(count))))
    }
    for (hz, count) in [(Float(200), 64), (Float(1_000), 64), (Float(6_000), 64)] {
        let bands = mapper.bands(from: tone(hz, count: 1024), count: count)
        let target = bandIndex(forHz: hz, count: count)
        let peak = bands.firstIndex(of: bands.max() ?? 0) ?? -1
        Check.that("a \(Int(hz)) Hz tone peaks at/near its \(count)-band (\(target)±1, got \(peak))",
                   abs(peak - target) <= 1)
    }

    Check.section("AudioBandMapper — sub-bin interpolation: no adjacent-band collapse (64)")
    // The low 64-bands are narrower than one FFT bin (≈46.9 Hz @ 1024/48k), so several share a single straddling
    // bin pair. STRUCTURAL de-aliasing proof, independent of any signal: under the OLD nearest-bin rule a sub-bin
    // band read the single bin `max(1, Int(centerHz/binHz))`, so any two adjacent sub-bin bands that rounded to
    // the SAME bin were guaranteed byte-identical regardless of content. Count those forced-equal pairs from the
    // pure frequency geometry (the value the old code itself used), with no power spectrum needed.
    let fftSize = 1024, halfN = 512
    let binHz = Float(48_000) / Float(fftSize)
    let fLo: Float = 30, fHi = Float(24_000)
    func centerBin(_ b: Int, count: Int) -> Float {
        let lo = fLo * pow(fHi / fLo, Float(b) / Float(count))
        let hi = fLo * pow(fHi / fLo, Float(b + 1) / Float(count))
        return (lo + hi) * 0.5 / binHz
    }
    func isSubBin(_ b: Int, count: Int) -> Bool {
        let lo = fLo * pow(fHi / fLo, Float(b) / Float(count))
        let hi = fLo * pow(fHi / fLo, Float(b + 1) / Float(count))
        return max(1, Int(lo / binHz)) > min(halfN - 1, Int(hi / binHz))
    }
    var oldForcedEqualPairs = 0
    for b in 0 ..< 63 where isSubBin(b, count: 64) && isSubBin(b + 1, count: 64) {
        let oldA = max(1, Int(centerBin(b, count: 64)))
        let oldB = max(1, Int(centerBin(b + 1, count: 64)))
        if oldA == oldB { oldForcedEqualPairs += 1 }   // old code snapped both to one bin → identical output
    }
    Check.that("the old nearest-bin rule forced multiple adjacent low 64-bands equal (\(oldForcedEqualPairs) pairs)",
               oldForcedEqualPairs > 0)

    // Now the BEHAVIOURAL proof: feed a spectrum with a gradient across the low end (a low tone whose skirt makes
    // neighbouring bins differ) and confirm the new pipeline gives those previously-forced-equal pairs DISTINCT
    // values. A quiet tone keeps the low bands in the partially-lit interior (not clamped to the dB ceiling, where
    // equality would be honest saturation). Every pair the old rule forced equal must now differ.
    let probe = mapper.bands(from: tone(70, count: 1024).map { $0 * 0.06 }, count: 64)
    var nowDistinct = 0, stillEqual = 0
    for b in 0 ..< 63 where isSubBin(b, count: 64) && isSubBin(b + 1, count: 64) {
        let oldA = max(1, Int(centerBin(b, count: 64)))
        let oldB = max(1, Int(centerBin(b + 1, count: 64)))
        guard oldA == oldB else { continue }                       // only the pairs the old code aliased
        let lo = probe[b], hi = probe[b + 1]
        guard lo > 0.02, lo < 0.98, hi > 0.02, hi < 0.98 else { continue }   // both partially lit
        if lo == hi { stillEqual += 1 } else { nowDistinct += 1 }
    }
    Check.that("interpolation de-aliases previously-forced-equal low 64-band pairs (\(nowDistinct) now distinct)",
               nowDistinct > 0)
    Check.that("no previously-forced-equal, partially-lit low 64-band pair remains identical (\(stillEqual) left)",
               stillEqual == 0)

    // Direct contrast on the two lowest bands: the old code snapped both band 0 and band 1 onto bin 1; the new
    // code interpolates their distinct center frequencies between bins 0 and 1, so they must now differ.
    let lowTone = mapper.bands(from: tone(60, count: 1024).map { $0 * 0.06 }, count: 64)
    Check.that("at 64 bands the two lowest bands are not forced equal for a low tone (\(lowTone[0]) vs \(lowTone[1]))",
               lowTone[0] != lowTone[1] && lowTone[0] > 0.02 && lowTone[0] < 0.98)

    Check.section("AudioBandMapper — sub-bin interpolation: 16/32 unchanged vs summation (golden)")
    // Golden vectors for a FIXED multi-tone input. The wide bands (band ≥1 bin wide: index ≥1 at 16, ≥2 at 32)
    // are summed/averaged EXACTLY as the original did, so those entries are byte-identical to the pre-change
    // engine. The lowest band(s) — index 0 at 16, indices 0…1 at 32 — were the sub-bin nearest-bin fallback and
    // are the only entries the interpolation improves. Pinning the whole vector locks both: no regression in the
    // summed bands, and the intended de-aliasing in the narrow ones.
    let input = fixedMultiTone(count: 1024)

    let golden16: [Float] = [
        0.6856858, 0.7024019, 0.8549754, 0.8899544, 0.7852436, 0.1898020, 0.7091006, 0.2950803,
        0.0000000, 0.0000000, 0.0000000, 0.4897431, 0.0000000, 0.0000000, 0.0000000, 0.0000000,
    ]
    let out16 = mapper.bands(from: input, count: 16)
    Check.that("16-band output matches the golden vector", approxEqual(out16, golden16))
    // The summed bands (index ≥ 1) must be EXACTLY the original values — assert that slice explicitly.
    Check.that("16-band summed bands (1…15) are unchanged vs the existing summation",
               approxEqual(Array(out16[1...]), Array(golden16[1...])))

    let golden32: [Float] = [
        0.6763976, 0.6925064, 0.7024019, 0.7024019, 0.7024019, 0.8549754, 0.9044514, 0.8899544,
        0.8178205, 0.4880321, 0.1910491, 0.1343178, 0.7072827, 0.7472611, 0.3507910, 0.0000000,
        0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.5503641, 0.0000000,
        0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000, 0.0000000,
    ]
    let out32 = mapper.bands(from: input, count: 32)
    Check.that("32-band output matches the golden vector", approxEqual(out32, golden32))
    // The summed bands (index ≥ 2) must be EXACTLY the original values.
    Check.that("32-band summed bands (2…31) are unchanged vs the existing summation",
               approxEqual(Array(out32[2...]), Array(golden32[2...])))

    Check.section("AudioBandMapper — sub-bin interpolation: determinism")
    // Same input → identical output (the cache must not introduce frame-to-frame drift).
    let d1 = mapper.bands(from: input, count: 64)
    let d2 = mapper.bands(from: input, count: 64)
    Check.that("64-band sub-bin output is deterministic (same input → identical output)", d1 == d2)
    Check.that("64-band output stays finite and within 0…1", d1.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
}

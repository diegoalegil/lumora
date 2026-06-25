// SPDX-License-Identifier: MIT
// Provenance: clean-room. Turns a window of PCM samples into Wallpaper Engine's 16/32/64 log-spaced
// audio bands (g_AudioSpectrum*), using Accelerate/vDSP for the FFT. The pipeline (Hann window → real
// FFT → magnitude → log-frequency binning → dB normalization → attack/release decay) is the textbook
// short-time spectrum; no GPL reference consulted. Pure & deterministic: same input → same output, so
// the band math is fully exercised by WESceneDynamicsChecks without any audio hardware.
import Accelerate

/// Maps mono PCM to normalized (0…1) magnitude bands. Owned and called from a single thread (the audio
/// capture queue); not intended to be shared concurrently.
public final class AudioBandMapper {
    /// FFT window size in samples (power of two). 1024 @ 48 kHz ≈ 21 ms — matches WE's responsiveness.
    public let fftSize: Int
    private let halfN: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]

    // How a single band reads the power spectrum. A band at least one FFT bin wide is the average of the
    // inclusive bin range `[start, end]` (unchanged from the original summation, so 16/32-band output is bit-
    // identical). A band narrower than one bin — common in the low end at 64 bands — is the power at the band's
    // CENTER frequency, linearly interpolated between bin `floor` and bin `floor + 1` by `frac ∈ [0, 1)`; this
    // gives neighbouring sub-bin bands distinct values instead of snapping them all to one nearest bin.
    private enum BandTap {
        case sum(start: Int, end: Int)
        case interp(floor: Int, frac: Float)
    }

    // The log-spaced band→power-bin mapping depends only on (count, sampleRate) for a fixed fftSize, so the
    // boundaries (and their pow() calls) are computed once per distinct pair and reused. In practice that's the
    // three counts 16/32/64 at one sampleRate, i.e. a handful of entries filled on the first few frames. Safe
    // without locking: a mapper is owned by a single thread (the audio capture queue), as documented above.
    private struct BandKey: Hashable { let count: Int; let sampleRateBits: UInt32 }
    private var bandTapCache: [BandKey: [BandTap]] = [:]

    // Normalization window in decibels: below `floorDB` reads as 0, at/above `ceilDB` as 1. Silence
    // (zero power) falls far below the floor and clamps to exactly 0 — the contract that keeps an
    // audio-reactive shader flat (not flickering) when nothing is playing.
    private let floorDB: Float = -60
    private let ceilDB: Float = -6
    // Release time constant (seconds) for the fall of a band after a peak — WE's bars jump up and ease
    // down. Attack is instantaneous (a new louder value replaces immediately).
    private let releaseTau: Float = 0.18

    public init?(fftSize: Int = 1024) {
        guard fftSize >= 2, fftSize.nonzeroBitCount == 1 else { return nil }   // power of two
        let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fftSize = fftSize
        self.halfN = fftSize / 2
        self.fft = fft
        self.hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                count: fftSize, isHalfWindow: false)
    }

    /// `count` normalized bands (0…1) for a window of `samples`, log-spaced from ~30 Hz to Nyquist,
    /// smoothed against `previous` with a frame-rate-independent release so peaks ease down rather than
    /// snap. `frameTime` is seconds since the previous call. Zero/short input → zero-padded; all-zero
    /// input → all-zero bands.
    public func bands(from samples: [Float], count: Int, previous: [Float]? = nil,
                      frameTime: Float = 1.0 / 60, sampleRate: Float = 48_000) -> [Float] {
        guard count > 0 else { return [] }
        // A non-positive or non-finite sample rate makes the bin width zero/NaN, and `Int(lo / binHz)` would then
        // trap on an infinite/NaN value. The capture rate is a fixed 48 kHz in practice; degrade to flat (silent)
        // bands rather than crash should a caller ever pass a bogus rate.
        guard sampleRate.isFinite, sampleRate > 0 else { return [Float](repeating: 0, count: count) }
        let power = magnitudeSpectrum(samples)               // halfN power bins
        let raw = logBands(power, count: count, sampleRate: sampleRate)
        let decay = max(0, min(1, exp(-max(0, frameTime) / releaseTau)))
        var out = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let prev = (previous != nil && previous!.count == count) ? previous![i] * decay : 0
            out[i] = max(raw[i], prev)
        }
        return out
    }

    /// The power spectrum (|X|²) of the windowed signal, length `halfN`; bin k ≈ k·sampleRate/fftSize Hz.
    private func magnitudeSpectrum(_ samples: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        let m = min(samples.count, fftSize)
        if m > 0 { for i in 0 ..< m { windowed[i] = samples[i] } }
        vDSP.multiply(windowed, hann, result: &windowed)

        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var power = [Float](repeating: 0, count: halfN)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // vDSP packs the Nyquist component into imagp[0], so squareMagnitudes leaves power[0] = DC² + Nyquist².
        // No band ever reads the true Nyquist bin (bands top out at halfN-1), yet the lowest sub-bin bands
        // interpolate into bin 0 — so strip the Nyquist term, leaving a clean DC magnitude there instead of
        // leaking ~24 kHz energy (cymbals/hiss/aliasing) into the deepest bass band.
        power[0] = real[0] * real[0]
        return power
    }

    /// How each of `count` log-spaced bands reads the power spectrum, memoized per (count, sampleRate). A band
    /// spanning at least one whole bin sums the inclusive range `[start, end]` exactly as the original did — so
    /// 16/32-band output is unchanged. A band narrower than one bin (its integer `[kStart, kEnd]` came out empty,
    /// the identical condition the old code used to take its nearest-bin fallback) instead samples the power at
    /// the band's center frequency, linearly interpolated between the two straddling bins. That removes the
    /// aliasing where adjacent low 64-bands all snapped to the same nearest bin and read identical values.
    private func bandTaps(count: Int, sampleRate: Float) -> [BandTap] {
        let key = BandKey(count: count, sampleRateBits: sampleRate.bitPattern)
        if let cached = bandTapCache[key] { return cached }
        let nyquist = sampleRate / 2
        let fLo: Float = 30
        let fHi = max(fLo * 2, nyquist)
        let binHz = sampleRate / Float(fftSize)
        var taps: [BandTap] = []
        taps.reserveCapacity(count)
        for b in 0 ..< count {
            let lo = fLo * pow(fHi / fLo, Float(b) / Float(count))
            let hi = fLo * pow(fHi / fLo, Float(b + 1) / Float(count))
            let kStart = max(1, Int(lo / binHz))
            let kEnd = min(halfN - 1, Int(hi / binHz))
            if kStart <= kEnd {                              // band ≥ one bin wide → exact average (unchanged)
                taps.append(.sum(start: kStart, end: kEnd))
            } else if halfN >= 2 {                           // sub-bin band → interpolate at center frequency
                // The continuous bin coordinate of the band center; clamp to [0, halfN-1] so floor and floor+1
                // stay valid. Allowing floor 0 lets two sub-bin bands whose centers both sit below bin 1 still
                // get distinct values (interpolating into the DC bin) instead of both snapping to bin 1; at the
                // very top a degenerate frac=0 reads the last bin exactly. (bin 0 is cleaned to pure DC in
                // magnitudeSpectrum, so this never folds in the packed-FFT Nyquist term.)
                let centerHz = (lo + hi) * 0.5
                let pos = min(Float(halfN - 1), max(0, centerHz / binHz))
                let floorBin = min(halfN - 2, Int(pos))
                let frac = pos - Float(floorBin)
                taps.append(.interp(floor: floorBin, frac: frac))
            } else {                                         // pathological one-bin spectrum → nearest bin
                let center = min(halfN - 1, max(1, Int((lo + hi) * 0.5 / binHz)))
                taps.append(.sum(start: center, end: center))
            }
        }
        bandTapCache[key] = taps
        return taps
    }

    /// Fold the linear power bins into `count` logarithmically-spaced bands, normalized to 0…1 in dB.
    private func logBands(_ power: [Float], count: Int, sampleRate: Float) -> [Float] {
        let norm = 1 / Float(fftSize * fftSize)              // bring |X|² into a stable range
        let taps = bandTaps(count: count, sampleRate: sampleRate)
        var bands = [Float](repeating: 0, count: count)
        for b in 0 ..< count {
            let mean: Float
            switch taps[b] {
            case let .sum(start, end):
                var sum: Float = 0
                for k in start ... end { sum += power[k] }   // ascending, matching the original loop
                mean = (sum / Float(end - start + 1)) * norm
            case let .interp(floor, frac):
                // Power at the band center frequency, linearly blended between the two straddling bins.
                let lerp = power[floor] + (power[floor + 1] - power[floor]) * frac
                mean = lerp * norm
            }
            let db = 10 * log10(mean + 1e-12)
            bands[b] = max(0, min(1, (db - floorDB) / (ceilDB - floorDB)))
        }
        return bands
    }
}

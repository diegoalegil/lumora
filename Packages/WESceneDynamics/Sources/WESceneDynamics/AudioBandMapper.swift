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
        let log2n = vDSP_Length((fftSize as NSNumber).intValue.trailingZeroBitCount)
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
        return power
    }

    /// Fold the linear power bins into `count` logarithmically-spaced bands, normalized to 0…1 in dB.
    private func logBands(_ power: [Float], count: Int, sampleRate: Float) -> [Float] {
        let nyquist = sampleRate / 2
        let fLo: Float = 30
        let fHi = max(fLo * 2, nyquist)
        let binHz = sampleRate / Float(fftSize)
        let norm = 1 / Float(fftSize * fftSize)              // bring |X|² into a stable range
        var bands = [Float](repeating: 0, count: count)
        for b in 0 ..< count {
            let lo = fLo * pow(fHi / fLo, Float(b) / Float(count))
            let hi = fLo * pow(fHi / fLo, Float(b + 1) / Float(count))
            var sum: Float = 0
            var n = 0
            var k = max(1, Int(lo / binHz))
            let kEnd = min(halfN - 1, Int(hi / binHz))
            while k <= kEnd { sum += power[k]; n += 1; k += 1 }
            if n == 0 {                                      // band narrower than a bin → nearest bin
                let center = min(halfN - 1, max(1, Int((lo + hi) * 0.5 / binHz)))
                sum = power[center]; n = 1
            }
            let mean = (sum / Float(n)) * norm
            let db = 10 * log10(mean + 1e-12)
            bands[b] = max(0, min(1, (db - floorDB) / (ceilDB - floorDB)))
        }
        return bands
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. The audio spectrum is injectable so animated/visualiser scenes can render
// deterministically (a synthetic spectrum in tests) instead of depending on live capture.

public enum AudioChannel: Sendable, Equatable { case left, right }

/// Source of audio FFT bands. Parity/tests inject a synthetic spectrum; the live app feeds silence.
public protocol AudioSpectrumProvider: Sendable {
    /// Returns `bands` normalized magnitudes (0…1) for the given channel. `bands` is 16/32/64.
    func spectrum(bands: Int, channel: AudioChannel) -> [Float]
}

/// A spectrum provider that always returns silence (all zeros) — the safe fallback when audio
/// capture is unavailable or permission is denied.
public struct SilentSpectrum: AudioSpectrumProvider {
    public init() {}
    public func spectrum(bands: Int, channel: AudioChannel) -> [Float] {
        Array(repeating: 0, count: max(0, bands))
    }
}

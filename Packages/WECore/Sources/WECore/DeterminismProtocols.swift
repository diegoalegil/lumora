// SPDX-License-Identifier: MIT
// Provenance: clean-room. Designed in from day 1 so the headless ParityRenderer is not a
// later retrofit: time, mouse, and audio are injectable, making animated scenes reproducible.
import simd

/// Source of the wallpaper clock. The live shell uses a wall clock; the parity harness injects
/// a fixed time so animated scenes render deterministically.
public protocol RenderClock: Sendable {
    /// Seconds since the wallpaper started.
    var seconds: Double { get }
}

/// Source of pointer position (normalized 0…1, origin top-left). Live = global cursor; parity = fixed.
public protocol MouseProvider: Sendable {
    var normalizedPosition: SIMD2<Double> { get }
}

public enum AudioChannel: Sendable, Equatable { case left, right }

/// Source of audio FFT bands. Live = ScreenCaptureKit+vDSP; parity = injected synthetic spectrum.
public protocol AudioSpectrumProvider: Sendable {
    /// Returns `bands` normalized magnitudes (0…1) for the given channel. `bands` is 16/32/64.
    func spectrum(bands: Int, channel: AudioChannel) -> [Float]
}

// MARK: - Trivial deterministic implementations (useful for tests / Phase 0)

/// A clock fixed at a constant time.
public struct FixedClock: RenderClock {
    public let seconds: Double
    public init(seconds: Double = 0) { self.seconds = seconds }
}

/// A mouse fixed at a constant normalized position (default: centered).
public struct FixedMouse: MouseProvider {
    public let normalizedPosition: SIMD2<Double>
    public init(_ position: SIMD2<Double> = SIMD2(0.5, 0.5)) { self.normalizedPosition = position }
}

/// A spectrum provider that always returns silence (all zeros) — the safe fallback when audio
/// capture is unavailable or permission is denied.
public struct SilentSpectrum: AudioSpectrumProvider {
    public init() {}
    public func spectrum(bands: Int, channel: AudioChannel) -> [Float] {
        Array(repeating: 0, count: max(0, bands))
    }
}

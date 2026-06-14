// SPDX-License-Identifier: MIT
// Provenance: clean-room. Field NAMES mirror Wallpaper Engine's public shader globals
// (g_Time, g_AudioSpectrum16/32/64, …) documented at docs.wallpaperengine.io/en/scene/shader.
import simd

/// The single per-frame boundary between the dynamics drivers (which WRITE it) and the
/// Metal render-core (which READS it once per draw). Field names match WE shader globals so
/// the binding layer can map them by name. NOTE: this is the Swift-side contract; WEScene is
/// responsible for packing it into std140 GPU buffers.
public struct FrameUniforms: Sendable, Equatable {
    /// Seconds since the wallpaper started (g_Time).
    public var time: Float
    /// Seconds since the previous frame (g_Frametime).
    public var frameTime: Float
    /// Render target size in pixels (g_Screen).
    public var screenSize: SIMD2<Float>
    /// 1/size — texel size (g_TexelSize).
    public var texelSize: SIMD2<Float>
    /// Normalized pointer position 0…1 (g_PointerPosition).
    public var pointerPosition: SIMD2<Float>
    /// Smoothed parallax offset driven by the pointer (g_ParallaxPosition).
    public var parallaxPosition: SIMD2<Float>

    /// Audio spectrum bands per channel (g_AudioSpectrum16/32/64). Lengths are fixed.
    public var audioSpectrumLeft16: [Float]
    public var audioSpectrumRight16: [Float]
    public var audioSpectrumLeft32: [Float]
    public var audioSpectrumRight32: [Float]
    public var audioSpectrumLeft64: [Float]
    public var audioSpectrumRight64: [Float]

    public init(
        time: Float = 0,
        frameTime: Float = 0,
        screenSize: SIMD2<Float> = .zero,
        texelSize: SIMD2<Float> = .zero,
        pointerPosition: SIMD2<Float> = SIMD2(0.5, 0.5),
        parallaxPosition: SIMD2<Float> = .zero,
        audioSpectrumLeft16: [Float] = Array(repeating: 0, count: 16),
        audioSpectrumRight16: [Float] = Array(repeating: 0, count: 16),
        audioSpectrumLeft32: [Float] = Array(repeating: 0, count: 32),
        audioSpectrumRight32: [Float] = Array(repeating: 0, count: 32),
        audioSpectrumLeft64: [Float] = Array(repeating: 0, count: 64),
        audioSpectrumRight64: [Float] = Array(repeating: 0, count: 64)
    ) {
        self.time = time
        self.frameTime = frameTime
        self.screenSize = screenSize
        self.texelSize = texelSize
        self.pointerPosition = pointerPosition
        self.parallaxPosition = parallaxPosition
        self.audioSpectrumLeft16 = audioSpectrumLeft16
        self.audioSpectrumRight16 = audioSpectrumRight16
        self.audioSpectrumLeft32 = audioSpectrumLeft32
        self.audioSpectrumRight32 = audioSpectrumRight32
        self.audioSpectrumLeft64 = audioSpectrumLeft64
        self.audioSpectrumRight64 = audioSpectrumRight64
    }

    /// A zeroed frame sized to a given render target, with texel size derived from it.
    public static func zeroed(screenSize: SIMD2<Float>) -> FrameUniforms {
        let texel = SIMD2<Float>(
            screenSize.x > 0 ? 1 / screenSize.x : 0,
            screenSize.y > 0 ? 1 / screenSize.y : 0
        )
        return FrameUniforms(screenSize: screenSize, texelSize: texel)
    }
}

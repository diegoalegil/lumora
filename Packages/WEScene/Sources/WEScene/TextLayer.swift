// SPDX-License-Identifier: MIT
// Provenance: clean-room. Renders a WE text object (clock, label, counter) to a Metal texture with CoreText:
// the string is either static or produced each frame by its SceneScript (a clock's update()), drawn in the
// object's font/colour. Apple CoreText/CoreGraphics + the SceneScript runtime; no GPL.
import Foundation
import CoreText
import CoreGraphics
import Metal
import WESceneDynamics

/// A prepared text layer: its font, colour, and the static string or the script that drives it. Caches the
/// last rendered texture so a clock only re-rasterises when its minute (the string) actually changes.
final class PreparedTextLayer {
    private let runtime: SceneScriptRuntime?
    private let staticText: String
    private let font: CTFont
    private let color: SIMD3<Float>
    private let device: MTLDevice
    /// Point size in scene units — maps the glyph height to the scene so the quad is the right size.
    let pointSize: Double

    private var cachedString: String?
    private var cachedTexture: MTLTexture?
    private var cachedSize: (w: Int, h: Int) = (0, 0)   // texture pixel dimensions (≈ scene units at 1:1)

    init(runtime: SceneScriptRuntime?, staticText: String, font: CTFont, color: SIMD3<Float>,
         pointSize: Double, device: MTLDevice) {
        self.runtime = runtime
        self.staticText = staticText
        self.font = font
        self.color = color
        self.pointSize = pointSize
        self.device = device
    }

    /// The current string (script-driven if scripted, else the static value).
    private func currentString() -> String { runtime?.updateString(staticText) ?? staticText }

    /// The texture for the current string and its pixel dimensions (which map ≈1:1 to scene units, the font
    /// being sized in scene units), rasterising and caching on change. nil if the string is empty or
    /// rasterisation fails — the caller then draws nothing for this layer.
    func currentTexture() -> (texture: MTLTexture, width: Int, height: Int)? {
        let string = currentString()
        guard !string.isEmpty else { return nil }
        if string == cachedString, let texture = cachedTexture { return (texture, cachedSize.w, cachedSize.h) }
        guard let (texture, w, h) = Self.rasterise(string, font: font, color: color, device: device) else { return nil }
        cachedString = string; cachedTexture = texture; cachedSize = (w, h)
        return (texture, w, h)
    }

    /// Rasterise `string` to a tightly-cropped RGBA texture via CoreText. Glyphs are drawn in `color`;
    /// the scene composites the result alpha-over (the layer tint is identity for text).
    private static func rasterise(_ string: String, font: CTFont, color: SIMD3<Float>,
                                  device: MTLDevice) -> (MTLTexture, Int, Int)? {
        let cg = CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: cg])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad = 6
        let w = max(1, Int(width.rounded(.up))) + pad * 2
        let h = max(1, Int((ascent + descent).rounded(.up))) + pad * 2
        guard w <= 8192, h <= 8192,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return (texture, w, h)
    }

    /// Load a CTFont from the scene's packaged .ttf bytes at `pointSize`, or a system monospaced fallback.
    static func makeFont(data: Data?, pointSize: Double) -> CTFont {
        if let data, let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) {
            return CTFontCreateWithGraphicsFont(cgFont, CGFloat(pointSize), nil, nil)
        }
        return CTFontCreateWithName("Menlo" as CFString, CGFloat(pointSize), nil)
    }
}

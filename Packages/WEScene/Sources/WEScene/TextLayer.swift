// SPDX-License-Identifier: MIT
// Provenance: clean-room. Renders a WE text object (clock, label, counter) to a Metal texture with CoreText:
// the string is either static or produced each frame by its SceneScript (a clock's update()), drawn in the
// object's font/colour. Apple CoreText/CoreGraphics + the SceneScript runtime; no GPL.
import Foundation
import CoreText
import CoreGraphics
import Metal
import Accelerate
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
    /// "left" | "center" | "right" — which edge of the rendered string sits at the layer origin.
    let horizontalAlign: String?

    private var cachedString: String?
    private var cachedTexture: MTLTexture?
    private var cachedSize: (w: Int, h: Int) = (0, 0)   // logical (scene-unit) dimensions for the quad
    private var cachedScale: Double = 0                 // pixel-density the cached texture was rasterised at

    init(runtime: SceneScriptRuntime?, staticText: String, font: CTFont, color: SIMD3<Float>,
         pointSize: Double, device: MTLDevice, horizontalAlign: String? = nil) {
        self.runtime = runtime
        self.staticText = staticText
        self.font = font
        self.color = color
        self.pointSize = pointSize
        self.device = device
        self.horizontalAlign = horizontalAlign
    }

    /// True when a SceneScript drives this text (a clock/counter), so the scene must run a render loop to
    /// re-evaluate it; a static label has no runtime and never changes.
    var isDynamic: Bool { runtime != nil }

    /// The current string (script-driven if scripted, else the static value).
    private func currentString() -> String { runtime?.updateString(staticText) ?? staticText }

    /// The texture for the current string plus its LOGICAL (scene-unit) dimensions for the quad. `pixelScale`
    /// is how many target pixels each scene unit will occupy (≈ the display backing scale): the glyphs are
    /// rasterised at that density so the text stays crisp when the scene is composited onto a Retina/4K target
    /// instead of being magnified from a 1× bitmap. Re-rasterises when the string or the scale changes. nil if
    /// the string is empty or rasterisation fails — the caller then draws nothing for this layer.
    func currentTexture(pixelScale: Double = 1) -> (texture: MTLTexture, width: Int, height: Int)? {
        let string = currentString()
        guard !string.isEmpty else { return nil }
        let scale = max(1, min(4, pixelScale))   // bound the supersample so a huge target can't blow up memory
        if string == cachedString, scale == cachedScale, let texture = cachedTexture {
            return (texture, cachedSize.w, cachedSize.h)
        }
        guard let (texture, w, h) = Self.rasterise(string, font: font, color: color, device: device, scale: scale)
        else { return nil }
        cachedString = string; cachedScale = scale; cachedTexture = texture; cachedSize = (w, h)
        return (texture, w, h)
    }

    /// Rasterise `string` to a tightly-cropped RGBA texture via CoreText. Glyphs are drawn in `color`; the scene
    /// composites the result alpha-over (the layer tint is identity for text). The bitmap is supersampled by
    /// `scale` (drawn through a scaled context) while the returned dimensions stay logical, so the quad keeps
    /// its scene-unit size but the texture carries enough texels to stay sharp at the target resolution.
    private static func rasterise(_ string: String, font: CTFont, color: SIMD3<Float>,
                                  device: MTLDevice, scale: Double) -> (MTLTexture, Int, Int)? {
        let cg = CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: cg])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad = 6
        let w = max(1, Int(width.rounded(.up))) + pad * 2                  // logical (scene-unit) size for the quad
        let h = max(1, Int((ascent + descent).rounded(.up))) + pad * 2
        let pw = max(1, Int((Double(w) * scale).rounded(.up)))             // supersampled texel dimensions
        let ph = max(1, Int((Double(h) * scale).rounded(.up)))
        guard pw <= 8192, ph <= 8192,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))                  // draw in logical coords into the hi-res bitmap
        ctx.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }

        // CoreGraphics emits premultiplied RGBA, but the scene composites text alpha-over (the blend multiplies
        // by source alpha again), which would multiply the glyph's antialiased edges by their coverage twice and
        // leave a dark fringe. Convert to straight alpha — the same un-premultiply the texture decoder applies to
        // packed images — so the edges blend cleanly.
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: pw * 4)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pw, height: ph, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0, withBytes: data, bytesPerRow: pw * 4)
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

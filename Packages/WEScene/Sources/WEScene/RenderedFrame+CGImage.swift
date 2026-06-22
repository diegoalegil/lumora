// SPDX-License-Identifier: MIT
// Provenance: clean-room. Bridges a rendered RGBA frame to a CGImage so a player can show it in a
// layer-backed view.
import CoreGraphics
import Foundation

public extension RenderedFrame {
    /// A CGImage backed by this frame's pixels, or nil if the buffer is too small.
    func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var bytes = rgba
        return bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

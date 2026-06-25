// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. CPU decompressors for the S3TC / DXT block-compressed texture formats, written
// from the PUBLIC block layout (RGB565 endpoints + 2-bit indices for the BC1 colour block; the 8-byte BC4
// alpha block of two endpoints + 3-bit indices used by BC3's alpha). Standard fixed-point interpolation;
// no GPL source was consulted.
import Foundation

/// CPU decoders that expand the block-compressed `.tex` formats (BC1/DXT1 and BC3/DXT5) to tightly-packed
/// straight-alpha RGBA8 bytes, for a renderer path that cannot upload native BC textures. These are
/// additive: `decodeFirstMip` keeps passing native block bytes through unchanged, and callers opt in to
/// CPU expansion via `decodeBlocksToRGBA8`.
public extension SceneTexture {
    /// Expand a block-compressed mip to tightly-packed RGBA8888 (`width*height*4` bytes), clamping the last
    /// row/column of blocks for dimensions that aren't multiples of four. Returns nil for any format that is
    /// not a CPU-decodable block format (BC1/BC3) so unknown formats degrade exactly as before.
    static func decodeBlocksToRGBA8(_ blocks: Data, format: TextureFormat, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let bc3: Bool
        switch format {
        case .dxt1: bc3 = false
        case .dxt5: bc3 = true
        default:    return nil          // BC2/RGBA8/RG88/R8 and unknown codes are not handled here.
        }

        let blockBytes = bc3 ? 16 : 8
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4
        guard blocks.count >= blocksX * blocksY * blockBytes else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        blocks.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            for by in 0 ..< blocksY {
                for bx in 0 ..< blocksX {
                    let blockBase = (by * blocksX + bx) * blockBytes
                    var colour = [UInt8](repeating: 0, count: 16 * 4)   // 4×4 texels, RGBA each
                    if bc3 {
                        // BC3: the alpha block owns the alpha channel; the colour block writes RGB only.
                        decodeBC4Alpha(src, blockBase, into: &colour)
                        decodeBC1Colour(src, blockBase + 8, opaque: true, writeAlpha: false, into: &colour)
                    } else {
                        decodeBC1Colour(src, blockBase, opaque: false, writeAlpha: true, into: &colour)
                    }
                    // Scatter the 4×4 block into the destination, clamping the partial edge blocks so a
                    // non-multiple-of-four dimension never writes past the last real row/column.
                    for ty in 0 ..< 4 {
                        let y = by * 4 + ty
                        if y >= height { break }
                        for tx in 0 ..< 4 {
                            let x = bx * 4 + tx
                            if x >= width { break }
                            let dst = (y * width + x) * 4
                            let s = (ty * 4 + tx) * 4
                            rgba[dst]     = colour[s]
                            rgba[dst + 1] = colour[s + 1]
                            rgba[dst + 2] = colour[s + 2]
                            rgba[dst + 3] = colour[s + 3]
                        }
                    }
                }
            }
        }
        return Data(rgba)
    }

    /// Decode one 8-byte BC1 colour block (two RGB565 endpoints + sixteen 2-bit indices) into the RGB (and,
    /// in punch-through mode, alpha) of a 4×4 RGBA tile. `opaque` forces the 4-colour interpolation and full
    /// alpha — BC3's colour block is always 4-colour; a standalone BC1 uses the endpoint order to choose the
    /// 4-colour or the 3-colour-plus-transparent (1-bit alpha) mode.
    private static func decodeBC1Colour(_ src: UnsafeBufferPointer<UInt8>, _ base: Int, opaque: Bool,
                                        writeAlpha: Bool, into tile: inout [UInt8]) {
        let c0 = UInt16(src[base]) | UInt16(src[base + 1]) << 8
        let c1 = UInt16(src[base + 2]) | UInt16(src[base + 3]) << 8

        var r = [Int](repeating: 0, count: 4)
        var g = [Int](repeating: 0, count: 4)
        var b = [Int](repeating: 0, count: 4)
        var a = [Int](repeating: 255, count: 4)
        (r[0], g[0], b[0]) = unpack565(c0)
        (r[1], g[1], b[1]) = unpack565(c1)

        // The 1-bit-alpha (3-colour) mode is selected purely by endpoint order: c0 <= c1. BC3's colour block
        // is documented as always 4-colour regardless of order, so `opaque` forces the 4-colour table.
        if opaque || c0 > c1 {
            r[2] = (2 * r[0] + r[1]) / 3; g[2] = (2 * g[0] + g[1]) / 3; b[2] = (2 * b[0] + b[1]) / 3
            r[3] = (r[0] + 2 * r[1]) / 3; g[3] = (g[0] + 2 * g[1]) / 3; b[3] = (b[0] + 2 * b[1]) / 3
        } else {
            r[2] = (r[0] + r[1]) / 2; g[2] = (g[0] + g[1]) / 2; b[2] = (b[0] + b[1]) / 2
            r[3] = 0; g[3] = 0; b[3] = 0; a[3] = 0          // the 4th index is transparent black
        }

        for ty in 0 ..< 4 {
            let row = src[base + 4 + ty]
            for tx in 0 ..< 4 {
                let index = Int((row >> (2 * tx)) & 0x3)
                let t = (ty * 4 + tx) * 4
                tile[t]     = UInt8(r[index])
                tile[t + 1] = UInt8(g[index])
                tile[t + 2] = UInt8(b[index])
                // For a standalone BC1 the colour block owns alpha (255, or 0 in punch-through). For BC3 the
                // alpha block already filled the channel, so the colour pass must leave it untouched.
                if writeAlpha { tile[t + 3] = UInt8(a[index]) }
            }
        }
    }

    /// Decode one 8-byte BC4 alpha block (two 8-bit endpoints + sixteen 3-bit indices) into the alpha channel
    /// of a 4×4 RGBA tile. This is exactly the alpha half of a BC3 block.
    private static func decodeBC4Alpha(_ src: UnsafeBufferPointer<UInt8>, _ base: Int, into tile: inout [UInt8]) {
        let a0 = Int(src[base])
        let a1 = Int(src[base + 1])
        var alpha = [Int](repeating: 0, count: 8)
        alpha[0] = a0
        alpha[1] = a1
        if a0 > a1 {
            // 8-value mode: six evenly-spaced interpolants between the endpoints (alpha[2…7]).
            for i in 1 ... 6 { alpha[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
        } else {
            // 6-value mode: four interpolants (alpha[2…5]) plus the fixed 0 and 255 extremes.
            for i in 1 ... 4 { alpha[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
            alpha[6] = 0
            alpha[7] = 255
        }

        // The sixteen 3-bit indices are packed little-endian across the six index bytes (two 24-bit halves).
        let lo = UInt64(src[base + 2]) | UInt64(src[base + 3]) << 8 | UInt64(src[base + 4]) << 16
        let hi = UInt64(src[base + 5]) | UInt64(src[base + 6]) << 8 | UInt64(src[base + 7]) << 16
        let bits = lo | (hi << 24)
        for texel in 0 ..< 16 {
            let index = Int((bits >> (UInt64(texel) * 3)) & 0x7)
            tile[texel * 4 + 3] = UInt8(alpha[index])
        }
    }

    /// Expand a 16-bit RGB565 colour to 8-bit-per-channel, replicating the high bits into the low bits so the
    /// full 0–255 range is reached (white maps to 255, not 248/252).
    private static func unpack565(_ c: UInt16) -> (Int, Int, Int) {
        let r5 = Int((c >> 11) & 0x1f)
        let g6 = Int((c >> 5) & 0x3f)
        let b5 = Int(c & 0x1f)
        let r = (r5 << 3) | (r5 >> 2)
        let g = (g6 << 2) | (g6 >> 4)
        let b = (b5 << 3) | (b5 >> 2)
        return (r, g, b)
    }
}

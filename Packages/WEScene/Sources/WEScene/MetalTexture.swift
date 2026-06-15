// SPDX-License-Identifier: MIT
// Provenance: clean-room. Maps a decoded WE texture to a Metal texture: WE's pixel formats to
// MTLPixelFormat (block-compressed DXT uploads directly as BCn), with the right bytes-per-row.
import Metal
import WEImporter

extension TextureFormat {
    /// The Metal pixel format this WE format uploads as. DXT1/3/5 map to BC1/2/3 and upload verbatim.
    var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .rgba8888: return .rgba8Unorm
        case .r8:       return .r8Unorm
        case .rg88:     return .rg8Unorm
        case .dxt1:     return .bc1_rgba
        case .dxt3:     return .bc2_rgba
        case .dxt5:     return .bc3_rgba
        }
    }

    /// True for the block-compressed (BCn) formats, which upload as 4×4 blocks.
    var isBlockCompressed: Bool {
        switch self {
        case .dxt1, .dxt3, .dxt5: return true
        case .rgba8888, .r8, .rg88: return false
        }
    }

    /// Bytes per row for a tightly-packed image of `width` pixels in this format.
    func bytesPerRow(width: Int) -> Int {
        switch self {
        case .rgba8888: return width * 4
        case .rg88:     return width * 2
        case .r8:       return width
        case .dxt1:     return max(1, (width + 3) / 4) * 8    // BC1: 8 bytes per 4×4 block
        case .dxt3, .dxt5: return max(1, (width + 3) / 4) * 16 // BC2/BC3: 16 bytes per 4×4 block
        }
    }
}

enum MetalTexture {
    /// Upload a decoded texture into a private-readable Metal texture, or nil if the device can't
    /// represent it (e.g. BC formats on an unsupported GPU) or allocation fails.
    static func make(_ decoded: DecodedTexture, device: MTLDevice) -> MTLTexture? {
        if decoded.format.isBlockCompressed, !device.supportsBCTextureCompression { return nil }
        // Bound the dimensions (Metal's max) before the bytes-per-row × rows arithmetic, so a crafted
        // texture can't overflow Int and trap.
        guard decoded.width > 0, decoded.height > 0, decoded.width <= 16384, decoded.height <= 16384 else { return nil }

        let bytesPerRow = decoded.format.bytesPerRow(width: decoded.width)
        // Rows of pixels, or rows of 4×4 blocks for the BCn formats.
        let rows = decoded.format.isBlockCompressed ? (decoded.height + 3) / 4 : decoded.height
        let required = bytesPerRow * rows
        // Never hand Metal a buffer smaller than the region it will read — that is an out-of-bounds
        // read (a crash). Skip the texture instead.
        guard decoded.pixels.count >= required else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: decoded.format.metalPixelFormat,
            width: decoded.width, height: decoded.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let region = MTLRegionMake2D(0, 0, decoded.width, decoded.height)
        decoded.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if decoded.format.isBlockCompressed {
                texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: base,
                                bytesPerRow: bytesPerRow, bytesPerImage: required)
            } else {
                texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        return texture
    }
}

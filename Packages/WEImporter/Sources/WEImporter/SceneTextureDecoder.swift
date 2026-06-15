// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Decodes the base mip of a Wallpaper Engine ".tex" texture to upload-ready
// bytes, using the per-mip layout reverse-confirmed from the user's OWN files (skip version-1 leading
// u32s, then width/height/isCompressed/decompressedSize/payloadSize/payload). LZ4 via Apple's
// Compression framework; embedded PNG/JPG via ImageIO. No GPL source was consulted.
import Foundation
import Compression
import ImageIO
import CoreGraphics

/// A decoded texture mip ready to hand to the GPU: raw pixel bytes (RGBA8888 / R8 / RG88) or
/// block-compressed bytes (DXT1/3/5) in `format`. `width`/`height` are the stored (power-of-two)
/// buffer dimensions; `imageWidth`/`imageHeight` are the content region inside it (for UVs/aspect).
public struct DecodedTexture: Sendable, Equatable {
    public let format: TextureFormat
    public let width: Int
    public let height: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let pixels: Data

    public init(format: TextureFormat, width: Int, height: Int, imageWidth: Int, imageHeight: Int, pixels: Data) {
        self.format = format
        self.width = width
        self.height = height
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pixels = pixels
    }
}

public extension SceneTexture {
    /// Decode the largest (first) mip of a `.tex` to upload-ready bytes. Handles the three storage
    /// shapes seen in the library: an embedded image file (PNG/JPG → RGBA8888 via ImageIO), an
    /// LZ4-compressed raw/block buffer, and a verbatim raw/block buffer.
    static func decodeFirstMip(_ data: Data) throws -> DecodedTexture {
        let (header, mipOffset) = try parse(data)
        let base = data.startIndex
        var cursor = mipOffset

        func u32() throws -> Int {
            guard cursor + 4 <= data.count else { throw SceneTextureError.truncated }
            let i = base + cursor
            let value = UInt32(data[i]) | UInt32(data[i + 1]) << 8
                | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            cursor += 4
            return Int(value)
        }

        // Each mip is preceded by (versionNumber − 1) sentinel/metadata u32s we don't need.
        let version = Int(header.mipContainerVersion.dropFirst(4)) ?? 1
        for _ in 0 ..< max(0, version - 1) { _ = try u32() }

        let mipWidth = try u32()
        let mipHeight = try u32()
        let isCompressed = try u32()
        let decompressedSize = try u32()
        let payloadSize = try u32()
        guard payloadSize >= 0, cursor + payloadSize <= data.count else { throw SceneTextureError.truncated }
        let payload = data.subdata(in: base + cursor ..< base + cursor + payloadSize)

        if Self.looksLikeImageFile(payload), let image = Self.decodeImageFile(payload) {
            return DecodedTexture(format: .rgba8888, width: image.width, height: image.height,
                                  imageWidth: header.imageWidth, imageHeight: header.imageHeight,
                                  pixels: image.rgba)
        }

        let pixels: Data
        if isCompressed == 1 {
            pixels = try Self.lz4Decompress(payload, expectedSize: decompressedSize)
        } else {
            pixels = payload
        }
        return DecodedTexture(format: header.format ?? .rgba8888, width: mipWidth, height: mipHeight,
                              imageWidth: header.imageWidth, imageHeight: header.imageHeight, pixels: pixels)
    }

    // MARK: - Payload decoders

    /// True if the bytes begin with a PNG or JPEG signature (an embedded FreeImage image).
    internal static func looksLikeImageFile(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4e, b[3] == 0x47 { return true }   // PNG
        if b[0] == 0xff, b[1] == 0xd8, b[2] == 0xff { return true }                 // JPEG
        return false
    }

    /// LZ4 (raw block) decompression to exactly `expectedSize` bytes.
    internal static func lz4Decompress(_ source: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var destination = Data(count: expectedSize)
        let produced = destination.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            source.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard produced == expectedSize else { throw SceneTextureError.decodeFailed }
        return destination
    }

    /// Decode an embedded PNG/JPEG to tightly-packed RGBA8 bytes via ImageIO.
    internal static func decodeImageFile(_ data: Data) -> (width: Int, height: Int, rgba: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var rgba = Data(count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (width, height, rgba) : nil
    }
}

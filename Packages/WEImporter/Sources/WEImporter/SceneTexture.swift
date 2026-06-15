// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Header reader for Wallpaper Engine's ".tex" image container, reverse-confirmed
// from the bytes of the user's OWN textures: a null-terminated "TEXV0005" container label, a "TEXI0001"
// image header (format + flags + container/image dimensions + one trailing u32), then a "TEXB000x"
// mip-data container label and a mip count. Validated across all 1265 textures in the library. The
// per-mip pixel data (LZ4 / block-compressed) is decoded separately. No GPL source was consulted.
import Foundation

/// The pixel layout of a `.tex` image, as named by Wallpaper Engine's format enum. The whole observed
/// library uses only these six; an unrecognised code is surfaced as the raw `formatCode` with a nil
/// `format` rather than failing.
public enum TextureFormat: Int, Sendable, Equatable, CaseIterable {
    case rgba8888 = 0   // 8-bit RGBA, uncompressed  (-> Metal .rgba8Unorm)
    case dxt5 = 4       // BC3                        (-> Metal .bc3_rgba)
    case dxt3 = 6       // BC2                        (-> Metal .bc2_rgba)
    case dxt1 = 7       // BC1                        (-> Metal .bc1_rgba)
    case rg88 = 8       // two-channel 8-bit          (-> Metal .rg8Unorm)
    case r8 = 9         // single-channel 8-bit       (-> Metal .r8Unorm)
}

/// How a texture's mip levels are stored.
public enum TextureCompression: Sendable, Equatable {
    /// Mip bytes are stored verbatim (mip container `TEXB0001`/`TEXB0002`).
    case none
    /// Mip bytes are LZ4-compressed (mip container `TEXB0003`/`TEXB0004`).
    case lz4
}

/// The parsed header of a `.tex` texture: enough to know its pixel format and dimensions and how its
/// mip data is stored, without yet decoding any pixels.
public struct SceneTextureHeader: Sendable, Equatable {
    /// The container label, e.g. `"TEXV0005"`.
    public let containerVersion: String
    /// The raw format enum value as written on disk.
    public let formatCode: Int
    /// The recognised pixel format, or nil if `formatCode` is one this build doesn't know.
    public let format: TextureFormat?
    /// The power-of-two storage dimensions of the texture.
    public let textureWidth: Int
    public let textureHeight: Int
    /// The actual image dimensions (≤ the texture dimensions).
    public let imageWidth: Int
    public let imageHeight: Int
    /// The mip-data container label, e.g. `"TEXB0003"`.
    public let mipContainerVersion: String
    /// The number of mip levels that follow the header.
    public let mipCount: Int

    /// Whether the mip data is LZ4-compressed, inferred from the mip container version (`TEXB0003`+).
    public var compression: TextureCompression {
        let version = Int(mipContainerVersion.dropFirst(4)) ?? 0
        return version >= 3 ? .lz4 : .none
    }
}

/// Why a `.tex` header could not be read.
public enum SceneTextureError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The header runs past the end of the data.
    case truncated
    /// The leading label isn't a `TEXV…` container signature.
    case badContainer(String)
    /// The mip label isn't a `TEXB…` signature where one was expected.
    case badMipContainer(String)

    public var description: String {
        switch self {
        case .truncated:               return ".tex header is truncated"
        case .badContainer(let s):     return "not a TEX container (label '\(s)')"
        case .badMipContainer(let s):  return "expected a TEXB mip container (found '\(s)')"
        }
    }
}

/// Reads the structural header of a Wallpaper Engine `.tex` texture.
public enum SceneTexture {
    /// Parse a `.tex` header from a file on disk.
    public static func readHeader(contentsOf url: URL) throws -> SceneTextureHeader {
        try readHeader(Data(contentsOf: url))
    }

    /// Parse a `.tex` header from its raw bytes.
    public static func readHeader(_ data: Data) throws -> SceneTextureHeader {
        let base = data.startIndex
        var cursor = 0

        func u32() throws -> Int {
            guard cursor + 4 <= data.count else { throw SceneTextureError.truncated }
            let i = base + cursor
            let value = UInt32(data[i]) | UInt32(data[i + 1]) << 8
                | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            cursor += 4
            return Int(value)
        }
        // A null-terminated ASCII label (the container and mip-container signatures use this shape).
        func cString() throws -> String {
            var end = base + cursor
            while end < data.endIndex, data[end] != 0 { end = data.index(after: end) }
            guard end < data.endIndex else { throw SceneTextureError.truncated }
            let text = String(decoding: data[(base + cursor) ..< end], as: UTF8.self)
            cursor = data.distance(from: base, to: end) + 1   // skip the terminator
            return text
        }

        let container = try cString()
        guard container.hasPrefix("TEXV") else { throw SceneTextureError.badContainer(container) }

        let imageHeader = try cString()   // "TEXI0001"
        guard imageHeader.hasPrefix("TEXI") else { throw SceneTextureError.badContainer(imageHeader) }

        let formatCode = try u32()
        _ = try u32()                     // flags
        let textureWidth = try u32()
        let textureHeight = try u32()
        let imageWidth = try u32()
        let imageHeight = try u32()
        _ = try u32()                     // a trailing u32 before the mip container

        let mipContainer = try cString()
        guard mipContainer.hasPrefix("TEXB") else { throw SceneTextureError.badMipContainer(mipContainer) }
        let mipCount = try u32()

        return SceneTextureHeader(
            containerVersion: container,
            formatCode: formatCode,
            format: TextureFormat(rawValue: formatCode),
            textureWidth: textureWidth,
            textureHeight: textureHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            mipContainerVersion: mipContainer,
            mipCount: mipCount
        )
    }
}

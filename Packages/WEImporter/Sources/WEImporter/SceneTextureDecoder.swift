// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Decodes the base mip of a Wallpaper Engine ".tex" texture to upload-ready
// bytes, using the per-mip layout reverse-confirmed from the user's OWN files (skip version-1 leading
// u32s, then width/height/isCompressed/decompressedSize/payloadSize/payload). LZ4 via Apple's
// Compression framework; embedded PNG/JPG via ImageIO. No GPL source was consulted.
import Foundation
import Compression
import ImageIO
import CoreGraphics
import Accelerate
import AVFoundation

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
        // Bound the mip dimensions (Metal's max) before any `width*height*4` arithmetic, so a crafted
        // header can't overflow Int and trap.
        guard mipWidth > 0, mipHeight > 0, mipWidth <= 16384, mipHeight <= 16384 else {
            throw SceneTextureError.decodeFailed
        }
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

        // A video-backed texture stores an MP4; show its first frame so the scene renders its artwork.
        if Self.looksLikeVideo(payload), let frame = Self.decodeVideoFirstFrame(payload) {
            return DecodedTexture(format: .rgba8888, width: frame.width, height: frame.height,
                                  imageWidth: frame.width, imageHeight: frame.height, pixels: frame.rgba)
        }

        let pixels: Data
        if isCompressed == 1 {
            // A decompressed size larger than one full RGBA8 frame is a multi-frame texture we can't read
            // as a single image — skip it rather than render a garbled frame.
            guard decompressedSize <= mipWidth * mipHeight * 4 else { throw SceneTextureError.decodeFailed }
            pixels = try Self.lz4Decompress(payload, expectedSize: decompressedSize)
        } else {
            // A raw payload bigger than one full RGBA8 frame is a multi-frame texture we can't read as a
            // single image (and isn't an MP4 we handled above). Fail cleanly so the layer is skipped
            // instead of uploading the bytes as a garbled, noisy frame.
            guard payloadSize <= mipWidth * mipHeight * 4 else { throw SceneTextureError.decodeFailed }
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

    /// The largest decoded mip we will allocate, to bound a hostile or corrupt size field. 256 MB
    /// comfortably covers an 8192×8192 RGBA texture; the real library tops out near 33 MB.
    internal static let maxDecodedBytes = 256 * 1024 * 1024

    /// LZ4 (raw block) decompression to exactly `expectedSize` bytes.
    internal static func lz4Decompress(_ source: Data, expectedSize: Int) throws -> Data {
        // `expectedSize` is an attacker-controlled u32 from the mip header — bound it before allocating.
        guard expectedSize > 0, expectedSize <= maxDecodedBytes else { throw SceneTextureError.decodeFailed }
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
        return pixels(from: image)
    }

    /// True if the bytes are an ISO-BMFF / MP4 container (a video-backed texture): the second box is the
    /// `ftyp` brand at offset 4.
    internal static func looksLikeVideo(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(8))
        return head.count >= 8 && head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70
    }

    /// Decode the first frame of an embedded MP4 (a video-backed texture) to RGBA8 via AVFoundation, so a
    /// scene built on a video texture renders its real artwork (still, for now) instead of nothing.
    internal static func decodeVideoFirstFrame(_ data: Data) -> (width: Int, height: Int, rgba: Data)? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard (try? data.write(to: tempURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tempURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return pixels(from: image)
    }

    /// The byte range of the embedded MP4 of a video-backed texture, or nil if the texture isn't a
    /// video. Cheap: it walks the mip header and sniffs the first 12 payload bytes, copying nothing.
    private static func videoPayloadRange(_ data: Data) -> Range<Int>? {
        guard let (header, mipOffset) = try? parse(data) else { return nil }
        let base = data.startIndex
        var cursor = mipOffset
        func u32() -> Int? {
            guard cursor + 4 <= data.count else { return nil }
            let i = base + cursor
            let value = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            cursor += 4
            return Int(value)
        }
        // (version-1) sentinels, then width/height/isCompressed/decompressedSize, then payloadSize.
        let skip = max(0, (Int(header.mipContainerVersion.dropFirst(4)) ?? 1) - 1) + 4
        for _ in 0 ..< skip where u32() == nil { return nil }
        guard let payloadSize = u32(), payloadSize > 12, base + cursor + payloadSize <= data.count else { return nil }
        let start = base + cursor
        guard looksLikeVideo(data.subdata(in: start ..< start + 12)) else { return nil }
        return start ..< start + payloadSize
    }

    /// Whether a `.tex` payload is a video-backed (animated) texture — an embedded MP4. Decodes nothing,
    /// so the renderer can cheaply decide to load a layer's frames off the render thread.
    static func isVideoTexture(_ data: Data) -> Bool { videoPayloadRange(data) != nil }

    /// Extract up to `count` evenly-spaced frames (RGBA8, resolution-capped) of a video-backed texture,
    /// with the clip's loop duration, so the renderer can animate it. Returns nil if it isn't a video
    /// or yields fewer than two frames.
    static func videoFrames(_ data: Data, count: Int = 24) -> (frames: [DecodedTexture], duration: Double)? {
        guard let range = videoPayloadRange(data) else { return nil }
        let payload = data.subdata(in: range)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard (try? payload.write(to: tempURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let asset = AVURLAsset(url: tempURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.01 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        // Demand the exact frame at each timestamp. With the default infinite tolerance the generator
        // returns the nearest keyframe, so many of the sampled times collapse onto the same frame and
        // the loop stutters; .zero on both sides gives a distinct frame per sample.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [DecodedTexture] = []
        for i in 0 ..< count {
            let time = CMTime(seconds: duration * Double(i) / Double(count), preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil), let px = pixels(from: image) else { continue }
            frames.append(DecodedTexture(format: .rgba8888, width: px.width, height: px.height,
                                         imageWidth: px.width, imageHeight: px.height, pixels: px.rgba))
        }
        return frames.count >= 2 ? (frames, duration) : nil
    }

    /// Draw a CGImage into tightly-packed, straight-alpha RGBA8 bytes (capped at Metal's max size).
    private static func pixels(from image: CGImage) -> (width: Int, height: Int, rgba: Data)? {
        let width = image.width, height = image.height
        // Dimensions come from an attacker-controlled embedded image; cap them at Metal's max texture
        // size so a crafted header can't request a multi-gigabyte allocation.
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        var rgba = Data(count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // CoreGraphics gives premultiplied RGBA; the renderer composites straight alpha, so undo
            // the premultiply to keep one convention end-to-end (no double-darkened transparent edges).
            var buffer = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            _ = vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, 0)
            return true
        }
        return ok ? (width, height, rgba) : nil
    }
}

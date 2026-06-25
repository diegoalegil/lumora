// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Exercises the CPU BC1/BC3 block decoders against hand-built blocks whose exact
// RGBA output is derived from the public S3TC/DXT layout (RGB565 endpoints, 2-bit colour indices, the
// BC4 alpha block of two endpoints + 3-bit indices). No GPL source was consulted.
import Foundation
import WEImporter

/// Pack sixteen 3-bit alpha indices into the six index bytes of a BC4/DXT5 alpha block (little-endian).
@MainActor private func packAlphaIndices(_ indices: [Int]) -> [UInt8] {
    var bits: UInt64 = 0
    for (texel, index) in indices.enumerated() { bits |= UInt64(index & 0x7) << (UInt64(texel) * 3) }
    var bytes = [UInt8]()
    for i in 0 ..< 6 { bytes.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
    return bytes
}

/// Read the RGBA of texel (x, y) out of a tightly-packed RGBA8 buffer of the given width.
@MainActor private func texel(_ rgba: Data, _ x: Int, _ y: Int, width: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let i = (y * width + x) * 4
    let b = [UInt8](rgba)
    return (b[i], b[i + 1], b[i + 2], b[i + 3])
}

@MainActor func runBCBlockChecks() {
    Check.section("BC block decoders")

    // BC1, 4-colour mode: endpoint c0 = max-red RGB565 (0xF800), c1 = black, c0 > c1 so the opaque
    // 4-colour table is used; every index is 0 → the whole 4×4 tile is endpoint 0. unpack565 replicates
    // the high bits, so 5-bit red 31 → 255 (a true solid red, not 248).
    let redBlock = Data([0x00, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    if let rgba = SceneTexture.decodeBlocksToRGBA8(redBlock, format: .dxt1, width: 4, height: 4) {
        Check.that("BC1 solid-red mip is 4×4×4 bytes", rgba.count == 4 * 4 * 4)
        var allRed = true
        for y in 0 ..< 4 { for x in 0 ..< 4 where texel(rgba, x, y, width: 4) != (255, 0, 0, 255) { allRed = false } }
        Check.that("BC1 solid-red decodes every texel to opaque (255,0,0,255)", allRed)
    } else {
        Check.that("BC1 solid-red block decodes", false)
    }

    // BC1, 1-bit-alpha (3-colour) mode: c0 (0x0000) <= c1 (0xF800) selects the punch-through table, where
    // colour index 3 is transparent black. Texel 0 uses index 3 (row-0 byte 0b00000011); the rest use
    // index 0 → opaque endpoint-0 (black).
    let punchBlock = Data([0x00, 0x00, 0x00, 0xF8, 0x03, 0x00, 0x00, 0x00])
    if let rgba = SceneTexture.decodeBlocksToRGBA8(punchBlock, format: .dxt1, width: 4, height: 4) {
        Check.that("BC1 punch-through texel 0 is fully transparent", texel(rgba, 0, 0, width: 4) == (0, 0, 0, 0))
        Check.that("BC1 punch-through texel 1 is opaque", texel(rgba, 1, 0, width: 4).3 == 255)
    } else {
        Check.that("BC1 punch-through block decodes", false)
    }

    // BC3 alpha ramp: a0=255 > a1=0 selects the 8-value alpha table [255,0,218,182,145,109,72,36].
    // All colour bytes are 0 (the colour block is a 4-colour all-black block); we only assert alpha.
    let alphaTable = [255, 0, 218, 182, 145, 109, 72, 36]
    let rampIndices = (0 ..< 16).map { $0 % 8 }                       // texels cycle through indices 0…7
    var bc3 = [UInt8]([255, 0]) + packAlphaIndices(rampIndices)        // 8-byte BC4 alpha block
    bc3 += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]            // 8-byte all-black BC1 colour block
    if let rgba = SceneTexture.decodeBlocksToRGBA8(Data(bc3), format: .dxt5, width: 4, height: 4) {
        var alphaMatches = true
        for texelIndex in 0 ..< 16 {
            let x = texelIndex % 4, y = texelIndex / 4
            let expected = UInt8(alphaTable[rampIndices[texelIndex]])
            if texel(rgba, x, y, width: 4).3 != expected { alphaMatches = false }
        }
        Check.that("BC3 alpha ramp decodes every index to its interpolated alpha", alphaMatches)
        Check.that("BC3 colour bytes from an all-black colour block are zero", texel(rgba, 0, 0, width: 4).0 == 0)
    } else {
        Check.that("BC3 alpha-ramp block decodes", false)
    }

    // Non-multiple-of-four dimensions must clamp the partial edge blocks instead of trapping: a 5×3 BC1
    // image is 2×1 blocks; the decoder writes only the 5×3 real region and produces exactly that many bytes.
    let twoBlocks = redBlock + redBlock                               // 2 horizontal BC1 blocks
    if let rgba = SceneTexture.decodeBlocksToRGBA8(twoBlocks, format: .dxt1, width: 5, height: 3) {
        Check.that("BC1 5×3 clamps to exactly 5×3×4 bytes", rgba.count == 5 * 3 * 4)
        Check.that("BC1 5×3 still decodes the spill-over column", texel(rgba, 4, 2, width: 5) == (255, 0, 0, 255))
    } else {
        Check.that("BC1 5×3 (non-multiple-of-4) block decodes", false)
    }

    // Additive guarantee: a non-CPU-decodable block format returns nil (degrades exactly as before), and the
    // default decodeFirstMip path still passes native block bytes through unchanged (no expansion).
    Check.that("BC2/DXT3 is not CPU-expanded (returns nil)",
               SceneTexture.decodeBlocksToRGBA8(Data(count: 16), format: .dxt3, width: 4, height: 4) == nil)
    Check.that("RGBA8 is not a block format here (returns nil)",
               SceneTexture.decodeBlocksToRGBA8(Data(count: 64), format: .rgba8888, width: 4, height: 4) == nil)

    // An undersized block payload (claims a block it doesn't have) returns nil rather than reading OOB.
    Check.that("an undersized BC1 payload returns nil",
               SceneTexture.decodeBlocksToRGBA8(Data(count: 4), format: .dxt1, width: 4, height: 4) == nil)

    // decodeFirstMip dispatch: a full .tex carrying one DXT1 block. Default keeps the historical passthrough
    // (block format + verbatim bytes); expandBlocks: true routes through the CPU decoder to RGBA8888.
    let redTex = buildBlockTex(format: 7, width: 4, height: 4, payload: redBlock)   // 7 = DXT1
    if let passthrough = try? SceneTexture.decodeFirstMip(redTex) {
        Check.that("decodeFirstMip default keeps DXT1 block format", passthrough.format == .dxt1)
        Check.that("decodeFirstMip default returns the verbatim block bytes", passthrough.pixels == redBlock)
    } else {
        Check.that("decodeFirstMip default decodes the DXT1 tex", false)
    }
    if let expanded = try? SceneTexture.decodeFirstMip(redTex, expandBlocks: true) {
        Check.that("decodeFirstMip(expandBlocks:) yields RGBA8888", expanded.format == .rgba8888)
        Check.that("decodeFirstMip(expandBlocks:) expands to 4×4 solid red",
                   texel(expanded.pixels, 0, 0, width: 4) == (255, 0, 0, 255) && expanded.pixels.count == 64)
    } else {
        Check.that("decodeFirstMip(expandBlocks:) decodes the DXT1 tex", false)
    }
}

/// Assemble a one-mip, uncompressed .tex carrying a verbatim block payload (mirrors the main harness's
/// buildTexWithMip but kept local so this Checks file is self-contained).
@MainActor private func buildBlockTex(format: Int, width: Int, height: Int, payload: Data) -> Data {
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func cstr(_ s: String) -> Data { var d = Data(s.utf8); d.append(0); return d }
    var d = cstr("TEXV0005"); d.append(cstr("TEXI0001"))
    d.append(le32(format)); d.append(le32(2))
    d.append(le32(width)); d.append(le32(height))
    d.append(le32(width)); d.append(le32(height))
    d.append(le32(0)); d.append(cstr("TEXB0002")); d.append(le32(1))     // version 2 → one leading u32
    d.append(le32(0))
    d.append(le32(width)); d.append(le32(height))
    d.append(le32(0)); d.append(le32(payload.count)); d.append(le32(payload.count))
    d.append(payload)
    return d
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room headless verification of the WEScene Metal renderer: renders to an offscreen
// texture and reads the pixels back. Skips gracefully when no Metal device is available (e.g. some CI).
import Foundation
import Metal
import CoreGraphics
import ImageIO
import WEImporter
import WEScene

// MARK: - Fixture helpers

@MainActor func le32(_ v: Int) -> Data {
    let u = UInt32(truncatingIfNeeded: v)
    return Data([UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)])
}
@MainActor func cstr(_ s: String) -> Data { var d = Data(s.utf8); d.append(0); return d }

/// A .tex carrying one raw (uncompressed) RGBA8 mip.
@MainActor func buildTexRGBA(_ w: Int, _ h: Int, _ pixels: Data) -> Data {
    var d = cstr("TEXV0005") + cstr("TEXI0001")
    d.append(le32(0)); d.append(le32(2))                       // format RGBA8888, flags
    d.append(le32(w)); d.append(le32(h)); d.append(le32(w)); d.append(le32(h)); d.append(le32(0))
    d.append(cstr("TEXB0002")); d.append(le32(1))              // mip container + mip count
    d.append(le32(0))                                          // (version-1) leading u32
    d.append(le32(w)); d.append(le32(h))
    d.append(le32(0)); d.append(le32(pixels.count)); d.append(le32(pixels.count))   // raw, sizes
    d.append(pixels)
    return d
}

/// A PKGV container packing the given files.
@MainActor func buildPKG(_ files: [(String, Data)]) -> Data {
    var toc = Data(); var blob = Data()
    toc.append(le32("PKGV0009".utf8.count)); toc.append(Data("PKGV0009".utf8))
    toc.append(le32(files.count))
    for (path, fileData) in files {
        let p = Data(path.utf8)
        toc.append(le32(p.count)); toc.append(p)
        toc.append(le32(blob.count)); toc.append(le32(fileData.count))
        blob.append(fileData)
    }
    return toc + blob
}

@MainActor func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ count: Int) -> Data {
    var d = Data(); d.reserveCapacity(count * 4)
    for _ in 0 ..< count { d.append(contentsOf: [r, g, b, 255]) }
    return d
}
@MainActor func centerRGB(_ frame: RenderedFrame) -> (Int, Int, Int) {
    let x = frame.width / 2, y = frame.height / 2
    let o = (y * frame.width + x) * 4
    return (Int(frame.rgba[o]), Int(frame.rgba[o + 1]), Int(frame.rgba[o + 2]))
}
@MainActor func near(_ a: Int, _ b: Int, _ tol: Int = 4) -> Bool { abs(a - b) <= tol }

/// Encode a frame to a PNG file (dev tooling for eyeballing a render).
@MainActor func writePNG(_ frame: RenderedFrame, to path: String) -> Bool {
    var rgba = frame.rgba
    let image = rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> CGImage? in
        guard let context = CGContext(data: raw.baseAddress, width: frame.width, height: frame.height,
                                      bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
    guard let image,
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// Optional dev mode: `swift run WESceneChecks <path/to/scene.pkg>` renders a real wallpaper to a PNG.
if CommandLine.arguments.count > 1 {
    let pkgPath = CommandLine.arguments[1]
    guard let renderer = SceneRenderer() else { print("no Metal device"); exit(0) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
          let package = try? ScenePackage.read(data),
          let document = try? SceneGraph.load(from: package) else { print("failed to load \(pkgPath)"); exit(1) }
    let w = min(document.orthoWidth > 0 ? document.orthoWidth : 1920, 3840)
    let h = min(document.orthoHeight > 0 ? document.orthoHeight : 1080, 2160)
    guard let frame = renderer.render(document, package: package, width: w, height: h) else { print("render failed"); exit(1) }
    var lo: UInt8 = 255, hi: UInt8 = 0
    for i in stride(from: 0, to: frame.rgba.count, by: 1021) { lo = min(lo, frame.rgba[i]); hi = max(hi, frame.rgba[i]) }
    let out = "/tmp/lumora_render.png"
    print("rendered \(document.layers.count) layer(s) @ \(w)x\(h); png=\(writePNG(frame, to: out)) -> \(out); pixel spread=\(Int(hi) - Int(lo)) (>0 means non-blank)")
    exit(0)
}

// MARK: - Render checks

guard let renderer = SceneRenderer() else {
    print("⚠︎ no Metal device available — skipping WEScene render checks (not a failure)")
    print("\n────────────────────────────────────────\nALL 0 CHECKS PASSED")
    exit(0)
}

print("WEScene: Metal device '\(renderer.device.name)', BC support: \(renderer.device.supportsBCTextureCompression)")

Check.section("SceneRenderer")
let red = SceneVec3(x: 1, y: 0, z: 0)

// 1) Clear-only: no texture -> the frame is the clear colour.
if let frame = renderer.render(texture: nil, alpha: 1, clearColor: red, width: 8, height: 8) {
    let (r, g, b) = centerRGB(frame)
    Check.that("clears to the scene colour (red)", near(r, 255) && near(g, 0) && near(b, 0))
    Check.that("frame is the requested size", frame.width == 8 && frame.height == 8)
    Check.that("frame has w*h*4 bytes", frame.rgba.count == 8 * 8 * 4)
} else {
    Check.that("clear-only render produced a frame", false)
}

// 2) A solid-green texture drawn full-screen covers the red clear colour.
let green = DecodedTexture(format: .rgba8888, width: 8, height: 8, imageWidth: 8, imageHeight: 8,
                           pixels: solid(0, 255, 0, 64))
if let frame = renderer.render(decoded: green, alpha: 1, clearColor: red, width: 8, height: 8) {
    let (r, g, b) = centerRGB(frame)
    Check.that("textured quad covers the frame (green)", near(r, 0) && near(g, 255) && near(b, 0))
} else {
    Check.that("textured render produced a frame", false)
}

// 3) Full pipeline: scene.json -> model -> material -> .tex (solid blue) -> rendered frame.
let sceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"1 0 0"},"objects":[{"name":"base","image":"models/m.json","origin":"4 4 0","alpha":1,"visible":true}]}"#.utf8)
let modelJSON = Data(#"{"material":"materials/mat.json"}"#.utf8)
let materialJSON = Data(#"{"passes":[{"shader":"genericimage2","textures":["t"]}]}"#.utf8)
let blueTex = buildTexRGBA(8, 8, solid(0, 0, 255, 64))
let pkgData = buildPKG([
    ("scene.json", sceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/t.tex", blueTex),
])
if let package = try? ScenePackage.read(pkgData),
   let document = try? SceneGraph.load(from: package),
   let frame = renderer.render(document, package: package, width: 8, height: 8) {
    let (r, g, b) = centerRGB(frame)
    Check.that("end-to-end scene renders its texture (blue)", near(r, 0) && near(g, 0) && near(b, 255))
} else {
    Check.that("end-to-end scene produced a frame", false)
}

Check.summarize()

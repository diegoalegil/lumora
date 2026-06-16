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

@MainActor func cgImage(_ frame: RenderedFrame) -> CGImage? {
    var rgba = frame.rgba
    return rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> CGImage? in
        CGContext(data: raw.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                  bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}

/// Render every `<dir>/*/scene.pkg` into a contact-sheet PNG, reporting non-blank / blank / failed.
@MainActor func batchRender(_ dir: String, renderer: SceneRenderer) {
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    let cellW = 240, cellH = 135, cols = 8
    var cells: [CGImage?] = []
    var ok = 0, blank = 0, failed = 0
    var uniformity: [(String, Double)] = []   // (scene, stddev of luma) — low stddev ≈ flat/solid render
    for name in names {
        let pkgPath = dir + "/" + name + "/scene.pkg"
        guard fm.fileExists(atPath: pkgPath) else { continue }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
              let package = try? ScenePackage.read(data),
              let document = try? SceneGraph.load(from: package),
              let frame = renderer.render(document, package: package, width: cellW, height: cellH) else {
            failed += 1; cells.append(nil); continue
        }
        var lo: UInt8 = 255, hi: UInt8 = 0
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for i in stride(from: 0, to: frame.rgba.count, by: 257) {
            let v = Double(frame.rgba[i]); lo = min(lo, frame.rgba[i]); hi = max(hi, frame.rgba[i])
            sum += v; sumSq += v * v; n += 1
        }
        if Int(hi) - Int(lo) > 8 { ok += 1 } else { blank += 1 }
        let variance = max(0, sumSq / n - (sum / n) * (sum / n))
        uniformity.append((name, variance.squareRoot()))
        cells.append(cgImage(frame))
    }
    print("flattest renders (low detail — likely solid-fill or decode issues):")
    for (name, std) in uniformity.sorted(by: { $0.1 < $1.1 }).prefix(10) {
        print(String(format: "  %@  std=%.1f", name, std))
    }
    let rows = max(1, (cells.count + cols - 1) / cols)
    let sheetW = cols * cellW, sheetH = rows * cellH
    if let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8,
                           bytesPerRow: sheetW * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        for (index, cell) in cells.enumerated() {
            guard let cell else { continue }
            let col = index % cols, row = index / cols
            ctx.draw(cell, in: CGRect(x: col * cellW, y: sheetH - (row + 1) * cellH, width: cellW, height: cellH))
        }
        if let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/lumora_contact_sheet.png") as CFURL,
                                                      "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil); _ = CGImageDestinationFinalize(dest)
        }
    }
    print("batch: \(ok) non-blank, \(blank) blank, \(failed) failed of \(cells.count) -> /tmp/lumora_contact_sheet.png")
}

// Optional dev mode: a scene.pkg path renders one wallpaper; a directory batch-renders a contact sheet.
if CommandLine.arguments.count > 1 {
    let arg = CommandLine.arguments[1]
    guard let renderer = SceneRenderer() else { print("no Metal device"); exit(0) }
    var isDir: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: arg, isDirectory: &isDir)
    if isDir.boolValue { batchRender(arg, renderer: renderer); exit(0) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: arg)),
          let package = try? ScenePackage.read(data),
          let document = try? SceneGraph.load(from: package) else { print("failed to load \(arg)"); exit(1) }
    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "layers" {   // dev: dump layer placement
        print("ortho \(Int(document.orthoWidth))x\(Int(document.orthoHeight)), \(document.layers.count) layers, usesPuppet=\(document.usesPuppet):")
        for (i, l) in document.layers.enumerated() {
            let sz = l.size.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-"
            print("  [\(i)] vis=\(l.visible ? 1 : 0) tex=\(l.texturePath ?? (l.isSolidLayer ? "SOLID" : "nil")) "
                + "origin=(\(Int(l.origin.x)),\(Int(l.origin.y))) size=\(sz) scale=(\(l.scale.x),\(l.scale.y)) "
                + "angles=(\(l.angles.x),\(l.angles.y),\(l.angles.z)) depth=(\(l.parallaxDepth.x),\(l.parallaxDepth.y)) "
                + "anim=\(l.originAnimation != nil) eff=\(l.effects.count) blend=\(l.blending ?? "-")")
        }
        exit(0)
    }
    let time = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 0) : 0
    // Optional width/height override (args 3 and 4) so a scene can be rendered at an arbitrary target —
    // e.g. a display's real pixel size/aspect — to reproduce size-dependent artifacts the scene's own
    // ortho size hides.
    let argW = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) : nil
    let argH = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) : nil
    let w = argW ?? min(document.orthoWidth > 0 ? document.orthoWidth : 1920, 3840)
    let h = argH ?? min(document.orthoHeight > 0 ? document.orthoHeight : 1080, 2160)
    let prepared = renderer.prepare(document, package: package)
    guard let frame = renderer.render(prepared, width: w, height: h, time: time) else { print("render failed"); exit(1) }
    let out = "/tmp/lumora_render\(time > 0 ? "_t\(Int(time))" : "").png"
    print("rendered \(prepared.layerCount) layer(s) @ \(w)x\(h) t=\(time) animated=\(prepared.hasAnimation); png=\(writePNG(frame, to: out)) -> \(out)")
    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "effect",
       let effectRenderer = EffectRenderer(device: renderer.device),
       let layer = document.layers.first(where: { !$0.effects.isEmpty }),
       let effect = layer.effects.first,
       let input = effectRenderer.makeTexture(rgba: frame.rgba, width: w, height: h),
       let white = effectRenderer.makeTexture(rgba: Data([255, 255, 255, 255]), width: 1, height: 1) {
        if let output = effectRenderer.apply(effect, to: input, package: package, auxTexture: white, width: w, height: h) {
            let outRGBA = effectRenderer.readback(output)
            let c = (h / 2 * w + w / 2) * 4
            let effected = RenderedFrame(width: w, height: h, rgba: outRGBA)
            print("applied effect '\(effect.name)' (center \(Array(frame.rgba[c ..< c + 4])) -> \(Array(outRGBA[c ..< c + 4]))) -> /tmp/lumora_effect.png = \(writePNG(effected, to: "/tmp/lumora_effect.png"))")
        } else {
            print("effect '\(effect.name)' failed to apply (likely a shader/uniform mismatch)")
        }
    }
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

// A crafted particle system can declare an unbounded rate/lifetime; the steady-state slot count must
// clamp into [1, maxcount] without trapping the Int conversion (rate × lifetime can overflow to inf).
Check.that("a normal rate × lifetime gives the expected slot count",
           SceneRenderer.particleInstanceCount(rate: 50, lifetimeUpper: 3, maxCount: 4000) == 150)
Check.that("the slot count is capped at maxcount",
           SceneRenderer.particleInstanceCount(rate: 1000, lifetimeUpper: 10, maxCount: 4000) == 4000)
Check.that("an overflowing rate × lifetime clamps to the cap instead of trapping",
           SceneRenderer.particleInstanceCount(rate: 1e300, lifetimeUpper: 1e300, maxCount: 4000) == 4000)
Check.that("a huge finite rate clamps to the cap",
           SceneRenderer.particleInstanceCount(rate: 1e200, lifetimeUpper: 1, maxCount: 4000) == 4000)
Check.that("a non-finite lifetime clamps to the cap",
           SceneRenderer.particleInstanceCount(rate: 1, lifetimeUpper: .infinity, maxCount: 4000) == 4000)
Check.that("at least one slot is always allocated",
           SceneRenderer.particleInstanceCount(rate: 0.0001, lifetimeUpper: 0.0001, maxCount: 4000) == 1)

// Aspect cover: a scene fills a differently-shaped target by scaling up the overflow axis (so it crops),
// never stretching. Matching or degenerate aspects are identity.
Check.that("a matching aspect is identity", SceneRenderer.coverScale(sceneAspect: 16.0 / 9, targetAspect: 16.0 / 9) == SIMD2<Float>(1, 1))
Check.that("a narrower (taller) target grows X and crops the sides", {
    let s = SceneRenderer.coverScale(sceneAspect: 16.0 / 9, targetAspect: 1.0)   // square target
    return s.x > 1.0 && s.y == 1.0
}())
Check.that("a wider target grows Y and crops top/bottom", {
    let s = SceneRenderer.coverScale(sceneAspect: 16.0 / 9, targetAspect: 21.0 / 9)
    return s.y > 1.0 && s.x == 1.0
}())
Check.that("a degenerate aspect is identity", SceneRenderer.coverScale(sceneAspect: 0, targetAspect: 1.78) == SIMD2<Float>(1, 1))

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
    let prepared = renderer.prepare(document, package: package)
    Check.that("prepare yields one layer", prepared.layerCount == 1)
    if let still = renderer.render(prepared, width: 8, height: 8, time: 0) {
        let (pr, pg, pb) = centerRGB(still)
        Check.that("prepared still render (t=0) matches the composite (blue)", near(pr, 0) && near(pg, 0) && near(pb, 255))
    }
} else {
    Check.that("end-to-end scene produced a frame", false)
}

// Graceful degradation: an effect that blanks the layer is dropped at prepare, so the layer keeps its
// artwork (blue) instead of being punched out to the clear colour (red).
let blankFrag = "varying vec4 v_TexCoord;\nuniform sampler2D g_Texture0;\nvoid main() { gl_FragColor = vec4(0.0); }"
let degradeJSON = Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"1 0 0"},"objects":[{"name":"base","image":"models/m.json","origin":"4 4 0","alpha":1,"effects":[{"file":"effects/blank/effect.json","passes":[{}]}]}]}"#.utf8)
let degradePkg = buildPKG([
    ("scene.json", degradeJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/t.tex", blueTex),
    ("effects/blank/effect.json", Data(#"{"passes":[{"material":"materials/effects/blank.json"}]}"#.utf8)),
    ("materials/effects/blank.json", Data(#"{"passes":[{"shader":"effects/blank"}]}"#.utf8)),
    ("shaders/effects/blank.frag", Data(blankFrag.utf8)),
])
if let package = try? ScenePackage.read(degradePkg), let document = try? SceneGraph.load(from: package),
   let frame = renderer.render(document, package: package, width: 8, height: 8) {
    let (r, g, b) = centerRGB(frame)
    Check.that("an effect that blanks the layer is dropped, keeping the artwork (blue)",
               near(r, 0) && near(g, 0) && near(b, 255))
}

// Effect pass machinery: a tint effect (transpiled WE shaders) halves the input texture.
if let effectRenderer = EffectRenderer(device: renderer.device) {
    Check.section("EffectRenderer")
    let effectFragment = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Tint;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * g_Tint; }
    """
    if let pipeline = effectRenderer.makePipeline(fragmentShader: effectFragment) {
        Check.that("builds an effect pipeline from transpiled WE shaders", true)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        inputDescriptor.usage = [.shaderRead]
        let input = renderer.device.makeTexture(descriptor: inputDescriptor)!
        var pixels = [UInt8](repeating: 200, count: 4 * 4 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        input.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 16)
        var tint: Float = 0.5
        let uniforms = Data(bytes: &tint, count: MemoryLayout<Float>.size)
        if let output = effectRenderer.apply(pipeline: pipeline, to: input, fragmentUniforms: uniforms, width: 4, height: 4) {
            let centerR = Int(effectRenderer.readback(output)[(2 * 4 + 2) * 4])
            Check.that("the tint effect halves the input (200 → ~100)", abs(centerR - 100) <= 6)
        } else {
            Check.that("the effect pass produced output", false)
        }
    } else {
        Check.that("builds an effect pipeline from transpiled WE shaders", false)
    }
}

Check.summarize()

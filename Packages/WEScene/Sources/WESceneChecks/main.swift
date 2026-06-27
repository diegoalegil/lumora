// SPDX-License-Identifier: MIT
// Provenance: clean-room headless verification of the WEScene Metal renderer: renders to an offscreen
// texture and reads the pixels back. Skips gracefully when no Metal device is available (e.g. some CI).
import Foundation
import Metal
import CoreGraphics
import ImageIO
import WEImporter
import WEScene
import WECore

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

@MainActor func solidA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8, _ count: Int) -> Data {
    var d = Data(); d.reserveCapacity(count * 4)
    for _ in 0 ..< count { d.append(contentsOf: [r, g, b, a]) }
    return d
}

/// Compare two raw RGBA byte buffers: the max per-channel delta and the count of bytes beyond `tol`. A size
/// mismatch is a total failure so a dropped or garbled reference can't slip through as a pass.
@MainActor func goldenDiff(_ a: Data, _ b: Data, tol: Int = 2) -> (maxDelta: Int, over: Int) {
    guard a.count == b.count, !a.isEmpty else { return (255, max(a.count, b.count)) }
    let aa = [UInt8](a), bb = [UInt8](b)
    var maxDelta = 0, over = 0
    for i in 0 ..< aa.count {
        let d = abs(Int(aa[i]) - Int(bb[i]))
        if d > maxDelta { maxDelta = d }
        if d > tol { over += 1 }
    }
    return (maxDelta, over)
}

/// An AudioSpectrumProvider that counts how many times the renderer asks for the spectrum — used to prove a
/// non-audio scene never triggers the per-frame audio-override build. Single-threaded test use only.
final class CountingSpectrum: AudioSpectrumProvider, @unchecked Sendable {
    private(set) var count = 0
    func spectrum(bands: Int, channel: AudioChannel) -> [Float] { count += 1; return [Float](repeating: 0, count: max(0, bands)) }
}

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
    if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "dumpentry" {
        if let e = package.entry(named: CommandLine.arguments[3]) {
            print(String(data: e.data, encoding: .utf8) ?? "<\(e.data.count) bytes, not utf8>")
        } else { print("no entry \(CommandLine.arguments[3])") }
        exit(0)
    }
    if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "dumptex" {
        if let e = package.entry(named: CommandLine.arguments[3]), let d = try? SceneTexture.decodeFirstMip(e.data),
           let f = renderer.render(decoded: d, alpha: 1, clearColor: SceneVec3(x: 0, y: 0, z: 0),
                                   width: min(d.imageWidth, 1024), height: min(d.imageHeight, 1024)) {
            // alpha-channel stats of the decoded RGBA — a layer that decodes RGB but draws invisible has alpha≈0
            let px = [UInt8](d.pixels); var aMin = 255, aMax = 0, aSum = 0; let n = px.count / 4
            for i in 0 ..< n { let a = Int(px[i * 4 + 3]); aMin = min(aMin, a); aMax = max(aMax, a); aSum += a }
            print("format=\(d.format) \(d.imageWidth)x\(d.imageHeight) alpha[min=\(aMin) max=\(aMax) mean=\(n > 0 ? aSum / n : 0)] -> \(writePNG(f, to: "/tmp/lumora_tex.png"))")
        } else { print("decode failed") }
        exit(0)
    }
    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "puppetonly" {
        let pups = document.layers.filter { $0.puppetPath != nil }
        let only = RenderableScene(orthoWidth: document.orthoWidth, orthoHeight: document.orthoHeight,
                                   clearColor: SceneVec3(x: 0.12, y: 0.12, z: 0.14), layers: pups, particleSystems: [])
        let w = min(document.orthoWidth, 1280), h = min(document.orthoHeight, 720)
        if let f = renderer.render(only, package: package, width: w, height: h) {
            print("puppet layers \(pups.count) -> \(writePNG(f, to: "/tmp/lumora_puppet.png"))")
        }
        exit(0)
    }
    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "mdldump" {   // dev: inspect puppet .mdl headers
        for layer in document.layers where layer.puppetPath != nil {
            guard let e = package.entry(named: layer.puppetPath!) else { continue }
            let d = [UInt8](e.data); let n = d.count
            func u32(_ o: Int) -> Int { o + 4 <= n ? Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 : -1 }
            func ascii(_ o: Int, _ len: Int) -> String { o + len <= n ? (String(bytes: d[o..<o+len], encoding: .ascii) ?? "?") : "?" }
            var mdls = -1
            if n >= 4 { for i in stride(from: n - 4, through: 0, by: -1) where d[i] == 0x4d && d[i+1] == 0x44 && d[i+2] == 0x4c && d[i+3] == 0x53 { mdls = i; break } }
            print("\(layer.puppetPath!): size=\(n) magic=\(ascii(0, 8)) mdls@\(mdls) ver=\(mdls >= 0 ? ascii(mdls+4, 4) : "-") bones=\(mdls >= 0 ? u32(mdls+13) : -1)")
            if mdls >= 0, mdls + 17 + 80 <= n {
                let s = mdls + 17
                print("   bind@\(s): " + (s..<s+80).map { String(format: "%02x", d[$0]) }.joined(separator: " "))
            }
        }
        exit(0)
    }
    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "layers" {   // dev: dump layer placement
        print("ortho \(Int(document.orthoWidth))x\(Int(document.orthoHeight)), \(document.layers.count) layers, usesPuppet=\(document.usesPuppet):")
        for (i, l) in document.layers.enumerated() {
            let sz = l.size.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-"
            print("  [\(i)] vis=\(l.visible ? 1 : 0) tex=\(l.texturePath ?? (l.isSolidLayer ? "SOLID" : "nil")) "
                + "origin=(\(Int(l.origin.x)),\(Int(l.origin.y))) size=\(sz) scale=(\(l.scale.x),\(l.scale.y)) "
                + "angles=(\(l.angles.x),\(l.angles.y),\(l.angles.z)) depth=(\(l.parallaxDepth.x),\(l.parallaxDepth.y)) "
                + "anim=\(l.originAnimation != nil) eff=\(l.effects.count) blend=\(l.blending ?? "-") "
                + "alpha=\(l.alpha) color=\(l.color)")
        }
        exit(0)
    }
    if CommandLine.arguments.count > 4, CommandLine.arguments[2] == "bench" {   // dev: time the live render() loop
        let frames = Int(CommandLine.arguments[3]) ?? 120
        let w = Int(CommandLine.arguments[4]) ?? 3024
        let h = CommandLine.arguments.count > 5 ? (Int(CommandLine.arguments[5]) ?? 1964) : 1964
        let prepared = renderer.prepare(document, package: package)
        _ = renderer.render(prepared, width: w, height: h, time: 0)   // warm up (compile pipelines, upload textures)
        var times: [Double] = []
        times.reserveCapacity(frames)
        for i in 0 ..< frames {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = renderer.render(prepared, width: w, height: h, time: Double(i) / 60.0)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)   // ms
        }
        let sorted = times.sorted()
        let mean = times.reduce(0, +) / Double(times.count)
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "bench %dx%d %d frames: mean %.2f ms (%.0f fps), median %.2f, p95 %.2f, min %.2f, max %.2f",
                     w, h, frames, mean, 1000.0 / mean, median, p95, sorted.first ?? 0, sorted.last ?? 0))
        exit(0)
    }
    if CommandLine.arguments.count > 4, CommandLine.arguments[2] == "asyncbench" {   // dev: drive the ASYNC live present path (semaphore + ring-buffered particle slots) — the TSan + throughput target
        let frames = Int(CommandLine.arguments[3]) ?? 120
        let w = Int(CommandLine.arguments[4]) ?? 1920
        let h = CommandLine.arguments.count > 5 ? (Int(CommandLine.arguments[5]) ?? 1200) : 1200
        let prepared = renderer.prepare(document, package: package)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.compositePixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: desc) else { print("asyncbench: no target"); exit(1) }
        _ = renderer.render(prepared, width: w, height: h, time: 0, into: target)   // warm up (sync, present nil)
        var times: [Double] = []; times.reserveCapacity(frames)
        let loopStart = DispatchTime.now().uptimeNanoseconds
        for i in 0 ..< frames {   // present closure non-nil → exercises the async path (no per-frame CPU wait)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = renderer.render(prepared, width: w, height: h, time: Double(i) / 60.0, into: target, present: { _ in })
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        renderer.waitForInFlight()
        let throughput = Double(DispatchTime.now().uptimeNanoseconds - loopStart) / 1_000_000 / Double(frames)
        let mean = times.reduce(0, +) / Double(times.count)
        // Correctness: a frame through the async present path must match the synchronous readback for the same
        // scene + time. Render the final time async, drain, read the target back, and diff it against readback.
        let tLast = Double(frames - 1) / 60.0
        _ = renderer.render(prepared, width: w, height: h, time: tLast, into: target, present: { _ in })
        renderer.waitForInFlight()
        var asyncBytes = Data(count: w * h * 4)
        asyncBytes.withUnsafeMutableBytes { raw in if let b = raw.baseAddress { target.getBytes(b, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) } }
        var match = "no readback ref"
        if let ref = renderer.render(prepared, width: w, height: h, time: tLast) {
            var d = 0; let n = min(asyncBytes.count, ref.rgba.count)
            for k in 0 ..< n where asyncBytes[k] != ref.rgba[k] { d += 1 }
            match = d == 0 ? "byte-identical" : "\(d) bytes differ"
        }
        print(String(format: "asyncbench %dx%d %d frames: throughput %.2f ms/frame (%.0f fps), per-call mean %.2f ms; async vs sync final frame: %@",
                     w, h, frames, throughput, 1000.0 / throughput, mean, match))
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
    print("rendered \(prepared.layerCount) layer(s) @ \(w)x\(h) t=\(time) animated=\(prepared.hasAnimation) "
        + "usesPuppet=\(document.usesPuppet) puppetReady=\(prepared.puppetReady); png=\(writePNG(frame, to: out)) -> \(out)")
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
    // No Metal device → not one render check can run. Fail LOUD so a headless CI can't silently report
    // "ALL GREEN" with zero render coverage; an intentional GPU-less run can opt out with LUMORA_ALLOW_NO_METAL.
    if ProcessInfo.processInfo.environment["LUMORA_ALLOW_NO_METAL"] != nil {
        print("⚠︎ no Metal device — WEScene render checks SKIPPED (0 ran); allowed via LUMORA_ALLOW_NO_METAL")
        print("\n────────────────────────────────────────\nRENDER CHECKS SKIPPED (no Metal device, 0 ran)")
        exit(0)
    }
    FileHandle.standardError.write(Data("✗ no Metal device — 0 of the WEScene render checks ran. Set LUMORA_ALLOW_NO_METAL=1 to allow skipping.\n".utf8))
    print("\n────────────────────────────────────────\nRENDER CHECKS DID NOT RUN (no Metal device)")
    exit(1)
}

print("WEScene: Metal device '\(renderer.device.name)', BC support: \(renderer.device.supportsBCTextureCompression)")

Check.section("SceneRenderer")
let red = SceneVec3(x: 1, y: 0, z: 0)

// Regression (fuzzer-found): Metal aborts the whole process if a render target has a zero dimension, and a
// view's bounds can momentarily be 0 during window setup/teardown or a display reconfiguration. render() must
// return nil for a non-positive size, not crash — while a valid size still renders.
Check.that("render(texture:) returns nil at zero width (no Metal abort)",
           renderer.render(texture: nil, alpha: 1, clearColor: red, width: 0, height: 8) == nil)
Check.that("render(texture:) returns nil at zero height",
           renderer.render(texture: nil, alpha: 1, clearColor: red, width: 8, height: 0) == nil)
Check.that("render(texture:) still renders at a valid size (guard didn't break the happy path)",
           renderer.render(texture: nil, alpha: 1, clearColor: red, width: 8, height: 8) != nil)

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

// The per-frame script delta (engine.frametime) is reconstructed from successive render times: a first frame
// or a non-advancing/backward time falls back to 1/60 (never a zero or negative dt), else it's the difference.
// It's computed once per frame so every scripted layer in a multi-visualiser scene shares the same real delta.
Check.that("script delta defaults to 1/60 on the first frame (no previous time)",
           SceneRenderer.scriptFrameDelta(time: 2.0, lastTime: nil) == 0.0166667)
Check.that("script delta is the advance between successive times",
           abs(SceneRenderer.scriptFrameDelta(time: 1.0, lastTime: 0.98) - 0.02) < 1e-9)
Check.that("a non-advancing time falls back to 1/60 (not a zero delta)",
           SceneRenderer.scriptFrameDelta(time: 1.0, lastTime: 1.0) == 0.0166667)
Check.that("a backward time (reload reset to 0) falls back to 1/60 (not negative)",
           SceneRenderer.scriptFrameDelta(time: 0.5, lastTime: 1.0) == 0.0166667)

// Regression (audit-found): a particle's per-cycle hash seed came from Int(time / lifetime), which traps when
// that quotient exceeds Int.max (a huge or non-finite render time) — the kind of degenerate time a buggy clock or
// a very long-lived session could produce. The particle render must complete at any time, not abort. A normal
// time still renders, proving the fold is behaviour-preserving.
let partPkg = buildPKG([
    ("scene.json", Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"0 0 0"},"objects":[{"name":"p","particle":"models/p.json","origin":"4 4 0","visible":true}]}"#.utf8)),
    ("models/p.json", Data(#"{"maxcount":50,"material":"materials/p.json","emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"8 8 0","rate":100}],"initializer":[{"name":"lifetimerandom","min":1.0,"max":2.0},{"name":"sizerandom","min":1,"max":2}],"operator":[{"name":"movement","gravity":"0 -1 0"}]}"#.utf8)),
    ("materials/p.json", Data(#"{"passes":[{"textures":["pt"]}]}"#.utf8)),
    ("materials/pt.tex", buildTexRGBA(4, 4, solid(255, 255, 255, 16))),
])
if let pkg = try? ScenePackage.read(partPkg), let doc = try? SceneGraph.load(from: pkg) {
    let prep = renderer.prepare(doc, package: pkg)
    Check.that("a particle scene renders at a normal time", renderer.render(prep, width: 8, height: 8, time: 5) != nil)
    Check.that("a particle scene renders at an extreme time without trapping (Int(cycle) fold)",
               renderer.render(prep, width: 8, height: 8, time: 1e30) != nil)
    Check.that("a particle scene renders at a non-finite time without trapping",
               renderer.render(prep, width: 8, height: 8, time: .infinity) != nil)
    Check.that("a normal particle system is kept", prep.particleCount == 1)
} else {
    Check.that("particle regression scene loads", false)
}
// A light-shaft / beam particle sprite renders in WE as a faint volumetric god-ray whose look depends on a soft
// falloff and the layer behind it; drawn straight as a packaged additive sprite it's a hard bright flare nothing
// like the scene (e.g. the balloon-girl wallpaper's blown-out streak over the balcony). Drop the system — the
// same policy the built-in procedural sprites already use — rather than composite a wrong bright blob.
let shaftPkg = buildPKG([
    ("scene.json", Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"0 0 0"},"objects":[{"name":"s","particle":"models/s.json","origin":"4 4 0","visible":true}]}"#.utf8)),
    ("models/s.json", Data(#"{"maxcount":16,"material":"materials/s.json","emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"8 8 0","rate":50}],"initializer":[{"name":"lifetimerandom","min":1.0,"max":2.0}]}"#.utf8)),
    ("materials/s.json", Data(#"{"passes":[{"blending":"additive","textures":["particle/light/light_shafts_0"]}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(shaftPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a light-shaft particle sprite is dropped (faint god-ray we can't match, not a bright flare)",
               renderer.prepare(doc, package: pkg).particleCount == 0)
} else {
    Check.that("shaft particle scene loads", false)
}

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
    // A fully static scene (one image, no parallax/keyframes/effects/particles/video/script) must report no
    // animation, so the player renders it once and parks the loop instead of re-compositing every frame.
    Check.that("a static single-image scene reports no animation", prepared.hasAnimation == false)
    if let still = renderer.render(prepared, width: 8, height: 8, time: 0) {
        let (pr, pg, pb) = centerRGB(still)
        Check.that("prepared still render (t=0) matches the composite (blue)", near(pr, 0) && near(pg, 0) && near(pb, 255))
    }
    // The prepared render path also guards a zero dimension (it reaches the effect pass before the composite).
    Check.that("render(prepared) returns nil at a zero dimension (no Metal abort)",
               renderer.render(prepared, width: 0, height: 8, time: 0) == nil)
    // An effect-free, script-free scene can't read the audio spectrum, so render() must NOT build the six
    // per-frame audio-override arrays — it should never call the provider at all.
    let counter = CountingSpectrum()
    _ = renderer.render(prepared, width: 8, height: 8, time: 0, audio: counter)
    Check.that("a non-audio scene never queries the audio spectrum", counter.count == 0)
} else {
    Check.that("end-to-end scene produced a frame", false)
}

// MARK: Golden image (fidelity)
// Committed clean-room references for the blend / alpha / tint compositing pipeline. Each scene is
// AUTHOR-DEFINED (no Wallpaper Engine pixels — firewall-safe) and is a full-screen uniform-texture quad, so
// every output pixel is the same 8-bit-unorm integer blend result and reproduces byte-for-byte across GPUs
// (no bilinear-filtering ULP). The committed .rgba reference gates regressions; each case also asserts its
// centre pixel against the hand-computed expected colour so a regenerated reference can't bake in a wrong
// render. Regenerate after an INTENTIONAL pipeline change: `LUMORA_REGEN_GOLDEN=1 swift run -q WESceneChecks`.
Check.section("Golden image (fidelity)")
do {
    let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    let regen = ProcessInfo.processInfo.environment["LUMORA_REGEN_GOLDEN"] != nil
    if regen { try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true) }
    let W = 16, H = 16, texels = 8 * 8

    func goldenCheck(_ name: String, _ frame: RenderedFrame?) {
        guard let frame else { Check.that("golden \(name): produced a frame", false); return }
        let ref = goldenDir.appendingPathComponent("\(name).rgba")
        if regen {
            try? frame.rgba.write(to: ref)
            print("  regenerated golden \(name) (\(frame.rgba.count) bytes)")
            return
        }
        guard let reference = try? Data(contentsOf: ref) else {
            Check.that("golden \(name): reference present (run LUMORA_REGEN_GOLDEN=1 to author it)", false); return
        }
        let (maxDelta, over) = goldenDiff(frame.rgba, reference)
        if over > 0 { _ = writePNG(frame, to: "/tmp/lumora_golden_\(name).png") }
        Check.that("golden \(name): matches the committed reference (maxΔ \(maxDelta), \(over) px over tol)",
                   maxDelta <= 2 && over == 0)
    }

    // 1) OVER + a known alpha composite: a half-alpha green texel over an opaque red clear.
    //    out = src·a + dst·(1−a) with a = 128/255 ⇒ ≈ (127, 128, 0).
    let g1 = DecodedTexture(format: .rgba8888, width: 8, height: 8, imageWidth: 8, imageHeight: 8,
                            pixels: solidA(0, 255, 0, 128, texels))
    let f1 = renderer.render(decoded: g1, alpha: 1, clearColor: SceneVec3(x: 1, y: 0, z: 0), width: W, height: H)
    if let f = f1 { let (r, g, b) = centerRGB(f)
        Check.that("golden over_alpha_half: centre is green@0.5 over red ≈ (127,128,0)", near(r, 127) && near(g, 128) && near(b, 0)) }
    goldenCheck("over_alpha_half", f1)

    // 2) Known TINT: an opaque white texture tinted by the object's colour (0.5, 0.25, 1) ⇒ ≈ (128, 64, 255).
    let tintPkg = buildPKG([
        ("scene.json", Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"1 0 0"},"objects":[{"name":"t","image":"models/m.json","origin":"4 4 0","color":"0.5 0.25 1","alpha":1,"visible":true}]}"#.utf8)),
        ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
        ("materials/mat.json", Data(#"{"passes":[{"shader":"genericimage2","textures":["t"]}]}"#.utf8)),
        ("materials/t.tex", buildTexRGBA(8, 8, solid(255, 255, 255, texels))),
    ])
    var f2: RenderedFrame?
    if let pkg = try? ScenePackage.read(tintPkg), let doc = try? SceneGraph.load(from: pkg) {
        f2 = renderer.render(doc, package: pkg, width: W, height: H)
        if let f = f2 { let (r, g, b) = centerRGB(f)
            Check.that("golden over_opaque_tint: centre is white × (0.5,0.25,1) ≈ (128,64,255)", near(r, 128) && near(g, 64) && near(b, 255)) }
    } else { Check.that("golden over_opaque_tint: scene loads", false) }
    goldenCheck("over_opaque_tint", f2)

    // 3) ADDITIVE: an opaque red sprite added over a blue clear ⇒ (255, 0, 128).
    let addPkg = buildPKG([
        ("scene.json", Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"0 0 0.5"},"objects":[{"name":"a","image":"models/m.json","origin":"4 4 0","alpha":1,"visible":true}]}"#.utf8)),
        ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
        ("materials/mat.json", Data(#"{"passes":[{"shader":"genericimage2","blending":"additive","textures":["t"]}]}"#.utf8)),
        ("materials/t.tex", buildTexRGBA(8, 8, solid(255, 0, 0, texels))),
    ])
    var f3: RenderedFrame?
    if let pkg = try? ScenePackage.read(addPkg), let doc = try? SceneGraph.load(from: pkg) {
        f3 = renderer.render(doc, package: pkg, width: W, height: H)
        if let f = f3 { let (r, g, b) = centerRGB(f)
            Check.that("golden additive: centre is red + blue ≈ (255,0,128)", near(r, 255) && near(g, 0) && near(b, 128)) }
    } else { Check.that("golden additive: scene loads", false) }
    goldenCheck("additive", f3)
}

// CAMetalLayer present path: render(into: target) must produce the EXACT bytes the readback render() does, so
// the live no-readback present path is provably pixel-identical to the verified offscreen path. Only the
// on-screen drawable present itself is owner-visual; the render is proven here.
do {
    let W = 24, H = 24
    let pkg = buildPKG([
        ("scene.json", Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"1 0 0"},"objects":[{"name":"t","image":"models/m.json","origin":"4 4 0","color":"0.5 0.25 1","alpha":1,"visible":true}]}"#.utf8)),
        ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
        ("materials/mat.json", Data(#"{"passes":[{"shader":"genericimage2","textures":["t"]}]}"#.utf8)),
        ("materials/t.tex", buildTexRGBA(8, 8, solid(255, 255, 255, 64))),
    ])
    if let package = try? ScenePackage.read(pkg), let document = try? SceneGraph.load(from: package),
       let reference = renderer.render(renderer.prepare(document, package: package), width: W, height: H, time: 0) {
        let prepared = renderer.prepare(document, package: package)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.compositePixelFormat,
                                                            width: W, height: H, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        if let target = renderer.device.makeTexture(descriptor: desc) {
            // present nil → composite encodes into target, commits and waits; target then holds the frame.
            _ = renderer.render(prepared, width: W, height: H, time: 0, into: target)
            var bytes = Data(count: W * H * 4)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                target.getBytes(base, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            }
            let (maxDelta, over) = goldenDiff(bytes, reference.rgba, tol: 0)
            Check.that("render(into:) is byte-identical to the readback render (maxΔ \(maxDelta), \(over) differ)",
                       maxDelta == 0 && over == 0)
        } else {
            Check.that("render(into:) equivalence: target texture allocated", false)
        }
    } else {
        Check.that("render(into:) equivalence scene loads + renders", false)
    }
}

// Conversely, a scene whose layer carries parallax depth DOES animate (the camera sway moves it over time),
// so it must report animation and keep its render loop running.
let parallaxJSON = Data(#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"1 0 0"},"objects":[{"name":"base","image":"models/m.json","origin":"4 4 0","alpha":1,"parallaxDepth":"0.5 0.5"}]}"#.utf8)
let parallaxPkg = buildPKG([
    ("scene.json", parallaxJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/t.tex", blueTex),
])
if let package = try? ScenePackage.read(parallaxPkg), let document = try? SceneGraph.load(from: package) {
    let prep = renderer.prepare(document, package: package)
    Check.that("a parallax-depth scene reports animation (keeps the loop running)", prep.hasAnimation == true)
    // Regression (sweep-found): a non-finite render time (NaN/inf from a misbehaving clock) flows into the
    // time-derived index math (the video-frame pick traps on Int(NaN)) and into the parallax sway as NaN,
    // displacing layers. render() now sanitises a non-finite time to 0 (the still composite), so an infinite or
    // NaN time renders identically to time 0 instead of trapping or producing NaN geometry.
    let atZero = renderer.render(prep, width: 8, height: 8, time: 0)
    let atInf = renderer.render(prep, width: 8, height: 8, time: .infinity)
    let atNaN = renderer.render(prep, width: 8, height: 8, time: .nan)
    Check.that("a non-finite render time renders (no trap, no NaN geometry)", atInf != nil && atNaN != nil)
    Check.that("an infinite/NaN time renders identically to time 0 (sanitised to the still composite)",
               atZero != nil && atInf?.rgba == atZero?.rgba && atNaN?.rgba == atZero?.rgba)
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

// A text layer's font comes from the untrusted package. Garbage font bytes must fall back to a system font,
// and a font that measures to non-finite/absurd glyph metrics is rejected (the text draws nothing) rather
// than trapping the Int conversions in the rasteriser — either way the scene still renders a frame.
let textJSON = Data(#"{"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},"objects":[{"name":"clock","text":"12:00","font":"fonts/bad.ttf","pointsize":24,"origin":"32 32 0","alpha":1,"visible":true,"color":"1 1 1"}]}"#.utf8)
let textPkg = buildPKG([
    ("scene.json", textJSON),
    ("fonts/bad.ttf", Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])),
])
if let package = try? ScenePackage.read(textPkg), let document = try? SceneGraph.load(from: package) {
    Check.that("a text scene with a garbage font renders without crashing",
               renderer.render(document, package: package, width: 64, height: 64) != nil)
}

// A layer's roll angle (angles.z) must be honoured — it was ignored, so rolled layers drew axis-aligned.
// A full-frame texture that's red on top and blue on the bottom, rolled 180°, must swap: the top reads blue.
var splitPixels = Data()
for y in 0 ..< 8 { for _ in 0 ..< 8 { splitPixels.append(contentsOf: y < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255]) } }
let splitTex = buildTexRGBA(8, 8, splitPixels)
@MainActor func renderRoll(_ angles: String) -> RenderedFrame? {
    let sceneJSON = Data((#"{"general":{"orthogonalprojection":{"width":8,"height":8},"clearcolor":"0 0 0"},"objects":[{"name":"r","image":"models/m.json","origin":"4 4 0","angles":""# + angles + #"","alpha":1,"visible":true}]}"#).utf8)
    let pkg = buildPKG([("scene.json", sceneJSON), ("models/m.json", modelJSON),
                        ("materials/mat.json", materialJSON), ("materials/t.tex", splitTex)])
    guard let package = try? ScenePackage.read(pkg), let document = try? SceneGraph.load(from: package) else { return nil }
    return renderer.render(document, package: package, width: 8, height: 8)
}
let topPixel = (1 * 8 + 4) * 4   // a pixel near the top edge, centre column
if let upright = renderRoll("0 0 0"), let rolled = renderRoll("0 0 3.14159") {
    Check.that("upright: the top of the layer is red", near(Int(upright.rgba[topPixel]), 255) && near(Int(upright.rgba[topPixel + 2]), 0))
    Check.that("rolled 180°: the top is now blue (the roll is applied)",
               near(Int(rolled.rgba[topPixel]), 0) && near(Int(rolled.rgba[topPixel + 2]), 255))
} else {
    Check.that("rolled-layer scene rendered", false)
}

// Effect pass machinery: a tint effect (transpiled WE shaders) halves the input texture.
if let effectRenderer = EffectRenderer(device: renderer.device) {
    Check.section("EffectRenderer")
    // makeTexture's width/height can come from untrusted data; it must reject out-of-range or non-positive
    // dimensions and a pixel buffer too small for them (which would read past the end of `rgba`), while a
    // correctly sized buffer still uploads.
    Check.that("makeTexture rejects oversized dimensions",
               effectRenderer.makeTexture(rgba: Data(count: 16), width: 1_000_000, height: 1_000_000) == nil)
    Check.that("makeTexture rejects a pixel buffer too small for its dimensions",
               effectRenderer.makeTexture(rgba: Data(count: 4), width: 100, height: 100) == nil)
    Check.that("makeTexture rejects non-positive dimensions",
               effectRenderer.makeTexture(rgba: Data(count: 4), width: 0, height: 4) == nil)
    Check.that("makeTexture accepts a correctly sized buffer",
               effectRenderer.makeTexture(rgba: Data(count: 2 * 2 * 4), width: 2, height: 2) != nil)
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

    // An effect fragment that reads a varying the fixed full-screen vertex never produces (v_Scale) can
    // only be drawn through the effect's OWN vertex — this is the interface mismatch that silently dropped
    // most effects. The guarantee is that pairing the own vertex links and runs correctly (asserted below).
    // Whether Metal's linker *rejects* the fixed-vertex pairing is driver-dependent — a discrete GPU fails
    // to link it, but a paravirtual device (e.g. CI runners) links it leniently — so that is not asserted.
    let ownVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    varying vec4 v_TexCoord;
    varying vec2 v_Scale;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = vec4(a_TexCoord, a_TexCoord);
        v_Scale = vec2(0.5, 0.25);
    }
    """
    let ownFragment = """
    varying vec4 v_TexCoord;
    varying vec2 v_Scale;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * vec4(v_Scale.x, v_Scale.y, 1.0, 1.0); }
    """
    _ = effectRenderer.makePipeline(fragmentShader: ownFragment)   // driver-dependent link result; not asserted
    if let ownPipeline = effectRenderer.makeVertexPipeline(vertexShader: ownVertex, fragmentShader: ownFragment) {
        Check.that("the effect's own vertex links the pipeline", true)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = renderer.device.makeTexture(descriptor: descriptor)!
        var pixels = [UInt8](repeating: 200, count: 4 * 4 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        input.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 16)
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let vertexUniforms = identity.withUnsafeBytes { Data($0) }
        if let output = effectRenderer.applyVertexEffect(pipeline: ownPipeline, to: input, vertexUniforms: vertexUniforms, width: 4, height: 4) {
            let rgba = effectRenderer.readback(output)
            let r = Int(rgba[(2 * 4 + 2) * 4]), g = Int(rgba[(2 * 4 + 2) * 4 + 1])
            Check.that("the own-vertex effect runs over the grid (r 200→~100, g 200→~50)", abs(r - 100) <= 6 && abs(g - 50) <= 6)
        } else {
            Check.that("the own-vertex effect produced output", false)
        }
    } else {
        Check.that("the effect's own vertex links the pipeline", false)
    }

    // A vertex that writes a varying the fragment ignores — sitting between two the fragment does use —
    // must still link: the fragment's stage_in mirrors the vertex's varyings so the locations don't drift
    // (the vhs regression, where v_TexCoordGlitchBase shifted v_TexCoordGlitch).
    let extraVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    varying vec4 v_TexCoord;
    varying vec2 v_Ignored;
    varying vec3 v_Used;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = vec4(a_TexCoord, a_TexCoord);
        v_Ignored = vec2(9.0);
        v_Used = vec3(0.5);
    }
    """
    let usingFragment = """
    varying vec4 v_TexCoord;
    varying vec3 v_Used;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * vec4(v_Used, 1.0); }
    """
    Check.that("a vertex varying the fragment ignores doesn't drift the locations or break the link",
               effectRenderer.makeVertexPipeline(vertexShader: extraVertex, fragmentShader: usingFragment) != nil)
}

Check.summarize()

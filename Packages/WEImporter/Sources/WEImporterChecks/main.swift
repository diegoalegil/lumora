// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room verification of WEImporter discovery + scanning against a synthetic Steam
// tree built in a temp directory (CLT-only equivalent of unit tests).
import Foundation
import Compression
import CoreGraphics
import ImageIO
import WECore
import WEImporter

// MARK: - Fixture helpers

let fm = FileManager.default

@MainActor func makeDir(_ url: URL) {
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
}

@MainActor func write(_ text: String, to url: URL) {
    makeDir(url.deletingLastPathComponent())
    try? Data(text.utf8).write(to: url)
}

/// Create a workshop item folder with an optional project.json and optional asset files.
@MainActor func makeItem(_ contentDir: URL, id: String, projectJSON: String?, assets: [String] = []) {
    let folder = contentDir.appendingPathComponent(id, isDirectory: true)
    makeDir(folder)
    if let projectJSON {
        write(projectJSON, to: folder.appendingPathComponent("project.json"))
    }
    for asset in assets {
        write("x", to: folder.appendingPathComponent(asset))
    }
}

@MainActor func isCorruptManifest(_ reason: ImportDiagnostic.Reason?) -> Bool {
    if case .corruptManifest = reason { return true }
    return false
}

// MARK: - Build a synthetic two-library Steam tree

let tmpRoot = fm.temporaryDirectory.appendingPathComponent("WEImporterChecks-\(UUID().uuidString)", isDirectory: true)
let steam1 = tmpRoot.appendingPathComponent("FakeSteam", isDirectory: true)
let steam2 = tmpRoot.appendingPathComponent("FakeSteam2", isDirectory: true)
let content1 = steam1.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
let content2 = steam2.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
makeDir(content1)
makeDir(content2)

// libraryfolders.vdf in the first steam root, pointing to both libraries (current layout).
let vdf = """
"libraryfolders"
{
\t"0"
\t{
\t\t"path"\t\t"\(steam1.path)"
\t\t"label"\t\t""
\t\t"apps"
\t\t{
\t\t\t"431960"\t\t"123456"
\t\t}
\t}
\t"1"
\t{
\t\t"path"\t\t"\(steam2.path)"
\t}
}
"""
write(vdf, to: steam1.appendingPathComponent("steamapps/libraryfolders.vdf"))

// Library 1: three good wallpapers and six broken ones.
makeItem(content1, id: "1001_video",
         projectJSON: #"{"title":"Clip","type":"video","file":"bg.mp4","preview":"p.jpg"}"#,
         assets: ["bg.mp4"])
makeItem(content1, id: "1002_web",
         projectJSON: #"{"title":"Page","type":"web","file":"index.html"}"#,
         assets: ["index.html"])
makeItem(content1, id: "1003_scene",
         projectJSON: #"{"title":"Scene","type":"scene","file":"scene.pkg"}"#,
         assets: ["scene.pkg"])
makeItem(content1, id: "1004_app",
         projectJSON: #"{"title":"App","type":"application","file":"app.exe"}"#,
         assets: ["app.exe"])
makeItem(content1, id: "1005_corrupt",
         projectJSON: "{ this is not valid json ")
makeItem(content1, id: "1006_noproj",
         projectJSON: nil)
makeItem(content1, id: "1007_nofile",
         projectJSON: #"{"title":"NoFile","type":"video","file":""}"#)
makeItem(content1, id: "1008_missingasset",
         projectJSON: #"{"title":"Gone","type":"video","file":"gone.mp4"}"#)
makeItem(content1, id: "1009_unknown",
         projectJSON: #"{"title":"Huh","type":"foo","file":"x.bin"}"#,
         assets: ["x.bin"])
makeItem(content1, id: "1010_traversal",
         projectJSON: #"{"title":"Escape","type":"video","file":"../../../../etc/passwd"}"#)

// Library 2: one good wallpaper, proving multi-library discovery.
makeItem(content2, id: "2001_video",
         projectJSON: #"{"title":"Clip2","type":"video","file":"bg.mp4"}"#,
         assets: ["bg.mp4"])

// MARK: - KeyValues parser

Check.section("KeyValues parser")
if let node = Check.noThrow("parse libraryfolders.vdf", { try KeyValuesParser.parse(vdf) }) {
    let libraryFolders = node.first("libraryfolders")
    Check.that("has libraryfolders", libraryFolders != nil)
    Check.that("two library entries", libraryFolders?.children.count == 2)
    Check.that("entry 0 path", libraryFolders?.first("0")?.first("path")?.stringValue == steam1.path)
    Check.that("entry 1 path", libraryFolders?.first("1")?.first("path")?.stringValue == steam2.path)
    Check.that("nested apps value",
               libraryFolders?.first("0")?.first("apps")?.first("431960")?.stringValue == "123456")
}

let withComments = """
// leading comment
"root"
{
    "a" "1" // trailing comment
    "b"
    {
        "c" "two words"
    }
}
"""
if let node = Check.noThrow("parse with comments", { try KeyValuesParser.parse(withComments) }) {
    Check.that("comment ignored, a == 1", node.first("root")?.first("a")?.stringValue == "1")
    Check.that("nested c == 'two words'", node.first("root")?.first("b")?.first("c")?.stringValue == "two words")
}

Check.that("case-insensitive key lookup",
           (try? KeyValuesParser.parse(#""Key" "v""#))?.first("KEY")?.stringValue == "v")
Check.throwsError("unbalanced braces throw", { try KeyValuesParser.parse(#""a" {"#) })
Check.throwsError("unterminated string throws", { try KeyValuesParser.parse("\"unterminated") })
// A pathologically deep file (thousands of nested objects) must be rejected, not crash the process by
// exhausting the recursion stack. A shallow file at the same shape still parses fine.
let deepVDF = String(repeating: #""a" {"#, count: 5000) + String(repeating: "}", count: 5000)
Check.throwsError("rejects pathologically deep nesting without crashing",
                  { try KeyValuesParser.parse(deepVDF) },
                  satisfies: { if case KeyValuesError.nestingTooDeep = $0 { return true }; return false })
Check.that("a modestly nested file still parses", {
    let nested = String(repeating: #""a" {"#, count: 64) + #""leaf" "v""# + String(repeating: "}", count: 64)
    return (try? KeyValuesParser.parse(nested)) != nil
}())

// MARK: - SteamLibraryLocator

Check.section("SteamLibraryLocator")
let locator = SteamLibraryLocator(steamRoots: [steam1])
let roots = locator.libraryRoots()
Check.that("discovers both libraries", roots.count == 2)
Check.that("includes steam1", roots.contains { $0.path == steam1.standardizedFileURL.path })
Check.that("includes steam2 via vdf", roots.contains { $0.path == steam2.standardizedFileURL.path })
Check.that("default steam root is ~/Library/Application Support/Steam",
           SteamLibraryLocator.defaultSteamRoots().first?.path.hasSuffix("Library/Application Support/Steam") == true)

let itemFolders = locator.workshopItemFolders()
Check.that("finds all 11 item folders", itemFolders.count == 11)
Check.that("includes lib2's item", itemFolders.contains { $0.lastPathComponent == "2001_video" })

let emptyLocator = SteamLibraryLocator(steamRoots: [tmpRoot.appendingPathComponent("does_not_exist")])
Check.that("missing root yields no items (no crash)", emptyLocator.workshopItemFolders().isEmpty)

// MARK: - WallpaperLibraryScanner

Check.section("WallpaperLibraryScanner")
let scanner = WallpaperLibraryScanner()
let result = scanner.scanLibrary(using: locator)

Check.that("4 wallpapers resolved", result.wallpapers.count == 4)
let types = result.wallpapers.map(\.type)
Check.that("two videos", types.filter { $0 == .video }.count == 2)
Check.that("one web", types.filter { $0 == .web }.count == 1)
Check.that("one scene", types.filter { $0 == .scene }.count == 1)
Check.that("resolves lib2 wallpaper",
           result.wallpapers.contains { $0.ref.folderURL.lastPathComponent == "2001_video" })

if let video = result.wallpapers.first(where: { $0.ref.folderURL.lastPathComponent == "1001_video" }) {
    Check.that("resolved video main asset exists on disk", fm.fileExists(atPath: video.mainFileURL.path))
    Check.that("resolved video main asset is bg.mp4", video.mainFileURL.lastPathComponent == "bg.mp4")
}

@MainActor func reason(_ folderName: String) -> ImportDiagnostic.Reason? {
    result.rejected.first { $0.folderURL.lastPathComponent == folderName }?.reason
}
Check.that("7 folders rejected", result.rejected.count == 7)
Check.that("'application' type rejected", reason("1004_app") == .unsupportedApplication)
Check.that("corrupt manifest rejected", isCorruptManifest(reason("1005_corrupt")))
Check.that("missing project.json rejected", reason("1006_noproj") == .missingProjectJSON)
Check.that("empty main file rejected", reason("1007_nofile") == .missingMainFile)
Check.that("missing main asset rejected", reason("1008_missingasset") == .missingMainAsset("gone.mp4"))
Check.that("unknown type rejected", reason("1009_unknown") == .unknownType("foo"))
Check.that("path-traversal main file rejected", reason("1010_traversal") == .unsafeMainFile("../../../../etc/passwd"))

// Direct single-folder scan also produces a diagnostic for a missing folder.
let ghost = scanner.scan(folderURL: content1.appendingPathComponent("nope"))
Check.that("scanning a folder with no project.json is a failure", {
    if case .failure(let d) = ghost, d.reason == .missingProjectJSON { return true }
    return false
}())

// A packaged scene declares file:scene.json (its unpacked source) but ships only scene.pkg — it must
// resolve to the package ScenePlayer reads, not be rejected as a missing asset.
let packagedScene = tmpRoot.appendingPathComponent("packaged_scene", isDirectory: true)
makeDir(packagedScene)
write(#"{"type":"scene","file":"scene.json","title":"Packaged"}"#, to: packagedScene.appendingPathComponent("project.json"))
write("PKG", to: packagedScene.appendingPathComponent("scene.pkg"))
Check.that("a packaged scene with only scene.pkg resolves to the package", {
    if case .success(let w) = scanner.scan(folderURL: packagedScene) {
        return w.type == .scene && w.mainFileURL.lastPathComponent == "scene.pkg"
    }
    return false
}())

// An extracted scene folder that ships BOTH the loose scene.json and the package must still resolve to the
// package (ScenePlayer reads PKGV, not loose JSON) — preferring scene.pkg whenever it exists.
let bothScene = tmpRoot.appendingPathComponent("both_scene", isDirectory: true)
makeDir(bothScene)
write(#"{"type":"scene","file":"scene.json","title":"Both"}"#, to: bothScene.appendingPathComponent("project.json"))
write("{}", to: bothScene.appendingPathComponent("scene.json"))
write("PKG", to: bothScene.appendingPathComponent("scene.pkg"))
Check.that("a scene folder with both scene.json and scene.pkg prefers the package", {
    if case .success(let w) = scanner.scan(folderURL: bothScene) {
        return w.mainFileURL.lastPathComponent == "scene.pkg"
    }
    return false
}())

// A scene with neither the named source nor a package is still a missing asset.
let emptyScene = tmpRoot.appendingPathComponent("empty_scene", isDirectory: true)
makeDir(emptyScene)
write(#"{"type":"scene","file":"scene.json","title":"Empty"}"#, to: emptyScene.appendingPathComponent("project.json"))
Check.that("a scene with no source and no package is rejected", {
    if case .failure(let d) = scanner.scan(folderURL: emptyScene), d.reason == .missingMainAsset("scene.json") { return true }
    return false
}())

// MARK: - LibrarySummary

Check.section("LibrarySummary")
Check.that("summarizes the scanned library",
           LibrarySummary.line(for: result) == "4 wallpapers (2 video, 1 web, 1 scene), 7 skipped")
Check.that("empty library reads cleanly",
           LibrarySummary.line(for: LibraryScanResult(wallpapers: [], rejected: [])) == "0 wallpapers")
let oneVideo = result.wallpapers.filter { $0.type == .video }.prefix(1)
Check.that("single wallpaper is singular",
           LibrarySummary.line(for: LibraryScanResult(wallpapers: Array(oneVideo), rejected: [])) == "1 wallpaper (1 video)")

// MARK: - WallpaperLibrary (presentation)

func mk(id: String, title: String?) -> ResolvedWallpaper {
    let folder = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
    let manifest = ProjectManifest(title: title, rawType: "video", file: "a.mp4")
    return ResolvedWallpaper(
        ref: WallpaperRef(id: id, folderURL: folder),
        type: .video,
        manifest: manifest,
        mainFileURL: folder.appendingPathComponent("a.mp4")
    )
}

Check.section("WallpaperLibrary")
Check.that("displayTitle uses the manifest title", WallpaperLibrary.displayTitle(mk(id: "i", title: "Hello")) == "Hello")
Check.that("displayTitle falls back to id when nil", WallpaperLibrary.displayTitle(mk(id: "i2", title: nil)) == "i2")
Check.that("displayTitle falls back to id when empty", WallpaperLibrary.displayTitle(mk(id: "i3", title: "")) == "i3")
Check.that("presentable sorts by title, case-insensitive",
           WallpaperLibrary.presentable([mk(id: "1", title: "Banana"), mk(id: "2", title: "apple")]).map(\.ref.id) == ["2", "1"])
Check.that("presentable de-duplicates by id",
           WallpaperLibrary.presentable([mk(id: "x", title: "A"), mk(id: "x", title: "A")]).count == 1)
Check.that("presentable breaks title ties by id",
           WallpaperLibrary.presentable([mk(id: "b", title: "Same"), mk(id: "a", title: "Same")]).map(\.ref.id) == ["a", "b"])
Check.that("presentable sorts a missing title by its id fallback",
           WallpaperLibrary.presentable([mk(id: "zzz", title: nil), mk(id: "aaa", title: "Mango")]).map(\.ref.id) == ["aaa", "zzz"])

// MARK: - ScenePackage (PKGV container reader)

@MainActor func le32(_ v: Int) -> Data {
    let u = UInt32(truncatingIfNeeded: v)
    return Data([UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)])
}

/// Assemble a PKGV container exactly as Wallpaper Engine writes it: a length-prefixed version label, a
/// TOC count, then [nameLen][utf8 path][offset][size] entries, then the contiguous blob region.
@MainActor func buildPKG(version: String, files: [(String, Data)]) -> Data {
    var toc = Data()
    var blob = Data()
    toc.append(le32(version.utf8.count)); toc.append(Data(version.utf8))
    toc.append(le32(files.count))
    for (path, fileData) in files {
        let p = Data(path.utf8)
        toc.append(le32(p.count)); toc.append(p)
        toc.append(le32(blob.count))      // offset is relative to the blob region
        toc.append(le32(fileData.count))
        blob.append(fileData)
    }
    return toc + blob
}

Check.section("ScenePackage")
let sceneBytes = Data(#"{"version":1}"#.utf8)
let matBytes = Data("material".utf8)
let pkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", sceneBytes),
    ("materials/anime.json", matBytes),
    ("models/キャラ.json", Data("model".utf8)),
])
if let read = Check.noThrow("reads a PKGV0009 package", { try ScenePackage.read(pkg) }) {
    Check.that("keeps the version label", read.version == "PKGV0009")
    Check.that("finds all three entries", read.entries.count == 3)
    Check.that("preserves TOC order",
               read.entries.map(\.path) == ["scene.json", "materials/anime.json", "models/キャラ.json"])
    Check.that("round-trips scene.json bytes", read.entry(named: "scene.json")?.data == sceneBytes)
    Check.that("round-trips a non-first entry", read.entry(named: "materials/anime.json")?.data == matBytes)
    Check.that("preserves UTF-8 / CJK paths", read.entries[2].path == "models/キャラ.json")
    Check.that("sceneJSON helper returns scene.json", read.sceneJSON?.path == "scene.json")
    Check.that("entry lookup is case-insensitive", read.entry(named: "SCENE.JSON") != nil)
}
Check.that("reads legacy PKGV0001 with an empty TOC",
           (try? ScenePackage.read(buildPKG(version: "PKGV0001", files: [])))?.entries.isEmpty == true)
Check.that("sceneJSON is nil for an empty package",
           (try? ScenePackage.read(buildPKG(version: "PKGV0001", files: [])))?.sceneJSON == nil)
Check.throwsError("rejects a non-PKGV signature",
                  { try ScenePackage.read(buildPKG(version: "ZIP!", files: [])) },
                  satisfies: { if case ScenePackageError.badSignature = $0 { return true }; return false })
Check.throwsError("rejects too-small data", { try ScenePackage.read(Data([1, 2, 3])) })
Check.throwsError("rejects a truncated TOC", {
    var d = le32(8); d.append(Data("PKGV0009".utf8)); d.append(le32(5))
    return try ScenePackage.read(d)
})
Check.throwsError("rejects an entry pointing out of bounds", {
    var d = le32(8); d.append(Data("PKGV0009".utf8)); d.append(le32(1))
    d.append(le32(1)); d.append(Data("x".utf8)); d.append(le32(0)); d.append(le32(9_999))
    return try ScenePackage.read(d)
}, satisfies: { if case ScenePackageError.entryOutOfBounds = $0 { return true }; return false })

// MARK: - SceneTexture (.tex header reader)

@MainActor func cstr(_ s: String) -> Data {
    var d = Data(s.utf8); d.append(0); return d
}

/// Assemble a .tex header as Wallpaper Engine writes it: TEXV/TEXI labels, format + flags + the two
/// dimension pairs + a trailing u32, then a TEXB mip-container label and a mip count.
@MainActor func buildTexHeader(format: Int, texW: Int, texH: Int, imgW: Int, imgH: Int,
                               mipContainer: String, mipCount: Int) -> Data {
    var d = Data()
    d.append(cstr("TEXV0005"))
    d.append(cstr("TEXI0001"))
    d.append(le32(format)); d.append(le32(2))            // flags
    d.append(le32(texW)); d.append(le32(texH))
    d.append(le32(imgW)); d.append(le32(imgH))
    d.append(le32(0xff5c6b7f))                           // the trailing u32 before the mip container
    d.append(cstr(mipContainer))
    d.append(le32(mipCount))
    return d
}

Check.section("SceneTexture")
let texDXT5 = buildTexHeader(format: 4, texW: 4096, texH: 4096, imgW: 3840, imgH: 2160,
                             mipContainer: "TEXB0003", mipCount: 1)
if let h = Check.noThrow("reads a .tex header", { try SceneTexture.readHeader(texDXT5) }) {
    Check.that("container version", h.containerVersion == "TEXV0005")
    Check.that("format code maps to DXT5", h.format == .dxt5)
    Check.that("texture (pow2) dims", h.textureWidth == 4096 && h.textureHeight == 4096)
    Check.that("image dims", h.imageWidth == 3840 && h.imageHeight == 2160)
    Check.that("mip container version", h.mipContainerVersion == "TEXB0003")
    Check.that("mip count", h.mipCount == 1)
    Check.that("TEXB0003 implies LZ4 compression", h.compression == .lz4)
}
Check.that("TEXB0002 is uncompressed",
           (try? SceneTexture.readHeader(buildTexHeader(format: 0, texW: 512, texH: 512, imgW: 500, imgH: 500,
                                                        mipContainer: "TEXB0002", mipCount: 3)))?.compression == TextureCompression.none)
Check.that("RGBA8888 format code maps",
           (try? SceneTexture.readHeader(buildTexHeader(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8,
                                                        mipContainer: "TEXB0004", mipCount: 1)))?.format == TextureFormat.rgba8888)
Check.that("R8 format code maps",
           (try? SceneTexture.readHeader(buildTexHeader(format: 9, texW: 8, texH: 8, imgW: 8, imgH: 8,
                                                        mipContainer: "TEXB0004", mipCount: 1)))?.format == TextureFormat.r8)
Check.that("an unknown format code is preserved, not fatal", {
    guard let h = try? SceneTexture.readHeader(buildTexHeader(format: 999, texW: 8, texH: 8, imgW: 8, imgH: 8,
                                                              mipContainer: "TEXB0003", mipCount: 1)) else { return false }
    return h.format == nil && h.formatCode == 999
}())
Check.throwsError("rejects a non-TEX container",
                  { try SceneTexture.readHeader(cstr("ZIPV0001") + cstr("TEXI0001") + le32(0)) },
                  satisfies: { if case SceneTextureError.badContainer = $0 { return true }; return false })
Check.throwsError("rejects a truncated header", { try SceneTexture.readHeader(cstr("TEXV0005")) })
Check.throwsError("rejects a bad mip container",
                  { try SceneTexture.readHeader(buildTexHeader(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8,
                                                               mipContainer: "JUNK0001", mipCount: 1)) },
                  satisfies: { if case SceneTextureError.badMipContainer = $0 { return true }; return false })

// MARK: - SceneTexture decode (mip payload: raw / LZ4 / embedded image)

/// Append a single mip to a header so `decodeFirstMip` has something to read.
@MainActor func buildTexWithMip(version: String, format: Int, mipW: Int, mipH: Int,
                                isCompressed: Int, decompressedSize: Int, payload: Data) -> Data {
    var d = buildTexHeader(format: format, texW: mipW, texH: mipH, imgW: mipW, imgH: mipH,
                           mipContainer: version, mipCount: 1)
    let v = Int(version.dropFirst(4)) ?? 1
    for _ in 0 ..< max(0, v - 1) { d.append(le32(0)) }        // leading sentinel/metadata u32s
    d.append(le32(mipW)); d.append(le32(mipH))
    d.append(le32(isCompressed)); d.append(le32(decompressedSize)); d.append(le32(payload.count))
    d.append(payload)
    return d
}

@MainActor func lz4Compress(_ src: Data) -> Data {
    let cap = src.count + 4096
    var dst = Data(count: cap)
    let n = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
        src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                      s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil,
                                      COMPRESSION_LZ4_RAW)
        }
    }
    return dst.prefix(n)
}

@MainActor func makePNG(_ w: Int, _ h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

Check.section("SceneTexture decode")
let rawPixels = Data((0 ..< 64).map { UInt8($0) })
if let dec = Check.noThrow("decodes a raw uncompressed mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0002", format: 0, mipW: 4, mipH: 4,
                                                    isCompressed: 0, decompressedSize: 64, payload: rawPixels))
}) {
    Check.that("raw format is RGBA8888", dec.format == .rgba8888)
    Check.that("raw mip dims", dec.width == 4 && dec.height == 4)
    Check.that("raw pixels pass through", dec.pixels == rawPixels)
}
let original = Data(repeating: 7, count: 4096)
let compressed = lz4Compress(original)
Check.that("lz4 fixture compresses", compressed.count > 0 && compressed.count < original.count)
if let dec = Check.noThrow("decodes an LZ4-compressed mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0003", format: 0, mipW: 32, mipH: 32,
                                                    isCompressed: 1, decompressedSize: 4096, payload: compressed))
}) {
    Check.that("lz4 round-trips to the original bytes", dec.pixels == original)
}
let dxtBlock = Data(repeating: 0xAB, count: 16)
if let dec = Check.noThrow("decodes a DXT5 block mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0004", format: 4, mipW: 4, mipH: 4,
                                                    isCompressed: 0, decompressedSize: 16, payload: dxtBlock))
}) {
    Check.that("DXT5 format preserved (not expanded)", dec.format == .dxt5)
    Check.that("DXT5 block bytes preserved", dec.pixels == dxtBlock)
}
let png = makePNG(8, 6)
Check.that("png fixture has the PNG signature", [UInt8](png.prefix(4)) == [0x89, 0x50, 0x4e, 0x47])
if let dec = Check.noThrow("decodes an embedded PNG mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0003", format: 0, mipW: 8, mipH: 6,
                                                    isCompressed: 0, decompressedSize: 0, payload: png))
}) {
    Check.that("PNG decodes to RGBA8888", dec.format == .rgba8888)
    Check.that("PNG decoded dims", dec.width == 8 && dec.height == 6)
    Check.that("PNG decoded to w*h*4 bytes", dec.pixels.count == 8 * 6 * 4)
}
Check.throwsError("rejects an LZ4 mip with a corrupt payload", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0003", format: 0, mipW: 32, mipH: 32,
                                                    isCompressed: 1, decompressedSize: 4096, payload: Data(repeating: 0, count: 8)))
})
Check.throwsError("rejects an absurd decompressed size (allocation bound)", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0003", format: 0, mipW: 4, mipH: 4,
                                                    isCompressed: 1, decompressedSize: 1_000_000_000, payload: Data(repeating: 0, count: 8)))
})

// MARK: - SceneGraph (scene.json -> renderable layers)

Check.section("SceneGraph")
let sceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0.7 0.7 0.7"},"objects":[{"name":"base","image":"models/m.json","origin":"960.0 540.0 0.0","scale":"1 1 1","alpha":1,"visible":true,"parallaxDepth":"0.4 0.5 0"},{"name":"sound","sound":["s.mp3"]}]}"#.utf8)
let modelJSON = Data(#"{"material":"materials/mat.json"}"#.utf8)
let materialJSON = Data(#"{"passes":[{"shader":"genericimage2","textures":["mytex"]}]}"#.utf8)
let scenePkgData = buildPKG(version: "PKGV0009", files: [
    ("scene.json", sceneJSON),
    ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON),
    ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = Check.noThrow("parses the scene package", { try ScenePackage.read(scenePkgData) }),
   let doc = Check.noThrow("loads the scene graph", { try SceneGraph.load(from: pkg) }) {
    Check.that("orthographic size", doc.orthoWidth == 1920 && doc.orthoHeight == 1080)
    Check.that("clear colour parsed", doc.clearColor.x == 0.7 && doc.clearColor.y == 0.7)
    Check.that("only image objects become layers", doc.layers.count == 1)
    if let layer = doc.layers.first {
        Check.that("layer name", layer.name == "base")
        Check.that("resolves image->model->material->texture", layer.texturePath == "materials/mytex.tex")
        Check.that("origin parsed", layer.origin.x == 960 && layer.origin.y == 540)
        Check.that("alpha parsed", layer.alpha == 1)
        Check.that("visible parsed", layer.visible == true)
        Check.that("parallax depth parsed", layer.parallaxDepth.x == 0.4 && layer.parallaxDepth.y == 0.5)
    }
    Check.that("a non-puppet scene is not flagged", doc.usesPuppet == false)
}

// A puppet-rigged object (its model references a bone/mesh .mdl) flags the whole scene, so the player can
// fall back to the static preview instead of drawing the unassembled body-part atlas.
let puppetModelJSON = Data(#"{"material":"materials/mat.json","puppet":"models/m_puppet.mdl"}"#.utf8)
let puppetPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", sceneJSON), ("models/m.json", puppetModelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(puppetPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a puppet-model scene is flagged usesPuppet", doc.usesPuppet == true)
}
// An audio visualiser binds a scene-graph SceneScript to a transform/visibility property. WE stores it
// inline (the whole module as the `script` string) or as a `scripts/…js` path; both must surface as the
// layer's `driverScript` so the renderer can clone the layer into bars.
let inlineScript = "'use strict';\\nexport function init(){}\\nexport function update(){ return thisLayer; }"
let visScene = #"{"objects":[{"name":"viz","image":"models/m.json","visible":{"value":true,"script":"INLINE"}}]}"#
    .replacingOccurrences(of: "INLINE", with: inlineScript)
let inlinePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(visScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(inlinePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("an inline visible.script becomes the layer's driverScript",
               doc.layers.first?.driverScript?.contains("function update") == true)
}
let pathScene = #"{"objects":[{"name":"viz","image":"models/m.json","scale":{"value":"1 1 1","script":"scripts/bars.js"}}]}"#
let pathPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(pathScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
    ("scripts/bars.js", Data("export function update(){}".utf8)),
])
if let pkg = try? ScenePackage.read(pathPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a scripts/…js path binding loads the script source as driverScript",
               doc.layers.first?.driverScript == "export function update(){}")
}
let plainPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", sceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(plainPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("an ordinary layer has no driverScript", doc.layers.first?.driverScript == nil)
    Check.that("an ordinary layer has no explicit alignment (centre by default)", doc.layers.first?.alignment == nil)
}
// A non-centre alignment (e.g. a full-screen background anchored bottom-left) must survive parsing so the
// renderer can shift the quad to land that corner on the layer's origin.
let alignScene = #"{"objects":[{"name":"bg","image":"models/m.json","alignment":"bottomleft","origin":"0 0 0","size":"3840 2160"}]}"#
let alignPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(alignScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(alignPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a layer's alignment is parsed", doc.layers.first?.alignment == "bottomleft")
}
// A text layer's point size comes from untrusted scene.json. A finite value is honoured; a non-finite one
// (an overflowing `1e400` parses to infinity) must fall back to the default so the glyph quads don't vanish.
let textSizePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"t","text":"Hi","pointsize":48}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(textSizePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a text layer's finite point size is kept", doc.layers.first?.pointSize == 48)
}
let badSizePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"t","text":"Hi","pointsize":1e400}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(badSizePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a non-finite point size falls back to the default", doc.layers.first?.pointSize == 32)
}
// A scripted/animated vector property is `{ "value": "x y z", "script": … }` — the base value must survive
// (it would otherwise fall back to the default, giving the layer the wrong scale/colour/rotation).
let scriptedVecScene = #"{"objects":[{"name":"v","image":"models/m.json","scale":{"value":"2 3 1","script":"s.js"},"color":{"value":"0.5 0.25 0.1"}}]}"#
let scriptedVecPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(scriptedVecScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(scriptedVecPkg), let doc = try? SceneGraph.load(from: pkg), let l = doc.layers.first {
    Check.that("a {value,script} scale uses its base value", l.scale.x == 2 && l.scale.y == 3)
    Check.that("a {value} colour uses its base value", l.color.x == 0.5 && l.color.y == 0.25)
}
// Parent hierarchy: a child's origin is relative to its parent's world position (plus the parent's scale on
// the offset). A parent at (1000,500) scale 2 with a child at local (10,20) → world (1020,540).
let parentScene = #"{"objects":[{"id":1,"name":"holder","image":"models/m.json","origin":"1000 500 0","scale":"2 2 1"},{"id":2,"name":"child","image":"models/m.json","parent":1,"origin":"10 20 0"},{"id":3,"name":"root","image":"models/m.json","origin":"640 360 0"}]}"#
let parentPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(parentScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(parentPkg), let doc = try? SceneGraph.load(from: pkg) {
    let child = doc.layers.first { $0.name == "child" }
    let root = doc.layers.first { $0.name == "root" }
    Check.that("a parented child resolves to its parent's world origin + scaled offset",
               child?.origin.x == 1020 && child?.origin.y == 540)
    Check.that("an unparented object is unchanged", root?.origin.x == 640 && root?.origin.y == 360)
}
// Full compounding: a child under a parent rotated 90° and scaled 2× has its offset scaled+rotated into the
// parent's frame and inherits the parent's scale/angle. Parent (1000,500) scale 2 angle π/2, child local
// origin (10,20) scale (3,3) angle 0.1 → world origin (960,520), scale (6,6), angle π/2+0.1.
let rotScene = #"{"objects":[{"id":1,"name":"holder","image":"models/m.json","origin":"1000 500 0","scale":"2 2 1","angles":"0 0 1.5707963"},{"id":2,"name":"child","image":"models/m.json","parent":1,"origin":"10 20 0","scale":"3 3 1","angles":"0 0 0.1"}]}"#
let rotPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(rotScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(rotPkg), let doc = try? SceneGraph.load(from: pkg),
   let child = doc.layers.first(where: { $0.name == "child" }) {
    Check.that("a rotated/scaled parent rotates the child offset",
               abs(child.origin.x - 960) < 0.5 && abs(child.origin.y - 520) < 0.5)
    Check.that("the parent's scale compounds into the child", abs(child.scale.x - 6) < 1e-4)
    Check.that("the parent's angle compounds into the child", abs(child.angles.z - (1.5707963 + 0.1)) < 1e-4)
}
// Scene-level bloom: parsed only when the flag is on and the strength is meaningful (bloom:true with strength 0
// is common and means off). Clamped against malformed values.
let bloomScene = #"{"general":{"bloom":true,"bloomstrength":1.5,"bloomthreshold":0.85},"objects":[{"image":"models/m.json"}]}"#
let bloomPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(bloomScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(bloomPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("scene bloom strength + threshold parse", doc.bloomStrength == 1.5 && doc.bloomThreshold == 0.85)
}
let noBloomScene = #"{"general":{"bloom":true,"bloomstrength":0.0},"objects":[{"image":"models/m.json"}]}"#
let noBloomPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(noBloomScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(noBloomPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("bloom:true with strength 0 means no bloom", doc.bloomStrength == 0)
}

// PuppetModel.parseMesh consumes an untrusted binary `.mdl`. Its bounds guards must reject malformed input
// with nil — never crash, read out of bounds, or hang — so a hostile package can't exploit the parser. (The
// happy path is covered end-to-end by the live-rendering puppet scenes; here we lock down the failure modes.)
Check.section("PuppetModel.parseMesh robustness")
Check.that("empty data → nil", PuppetModel.parseMesh(Data()) == nil)
Check.that("too-short data → nil", PuppetModel.parseMesh(Data([0x4d, 0x44, 0x4c, 0x56])) == nil)
Check.that("no MDLV magic → nil", PuppetModel.parseMesh(Data(repeating: 0, count: 256)) == nil)
// MDLV magic but no vertex marker in the window → nil (not a crash).
var magicOnly = Data([0x4d, 0x44, 0x4c, 0x56]); magicOnly.append(Data(repeating: 0, count: 256))
Check.that("MDLV magic with no vertex marker → nil", PuppetModel.parseMesh(magicOnly) == nil)
// MDLV + the vertex marker but an absurd vertex-block size must fail the bounds/stride guards, not over-read.
var badSize = Data([0x4d, 0x44, 0x4c, 0x56]); badSize.append(Data(repeating: 0, count: 0x12))
badSize.append(Data([0x0f, 0x00, 0x80, 0x01]))                 // vertex marker
badSize.append(Data([0xff, 0xff, 0xff, 0x7f]))                 // vertexBytes ≈ 2 GB
badSize.append(Data(repeating: 0xab, count: 64))
Check.that("MDLV with an out-of-range vertex size → nil (no over-read)", PuppetModel.parseMesh(badSize) == nil)
// Fuzz: deterministic pseudo-random buffers, half of them MDLV-prefixed, must all parse without crashing —
// reaching the assertion after the loop IS the test (an OOB/crash would abort the process before it).
var seed: UInt64 = 0x1234_5678
for trial in 0 ..< 200 {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let len = 32 + Int(UInt8(truncatingIfNeeded: seed >> 33)) * 4
    var bytes = [UInt8]()
    for _ in 0 ..< len {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
    }
    if trial % 2 == 0 { bytes[0] = 0x4d; bytes[1] = 0x44; bytes[2] = 0x4c; bytes[3] = 0x56 }
    _ = PuppetModel.parseMesh(Data(bytes))   // must not crash/OOB; result (nil or a bounded mesh) is fine
}
Check.that("200 fuzzed .mdl buffers parse without crashing", true)

Check.that("SceneVec3 parses a partial string", {
    let v = SceneVec3(parsing: "1.5 2"); return v.x == 1.5 && v.y == 2 && v.z == 0
}())
Check.that("SceneVec3 sanitizes non-finite components to 0", {
    let v = SceneVec3(parsing: "nan inf 1e400"); return v.x == 0 && v.y == 0 && v.z == 0
}())
Check.throwsError("rejects an empty package (no scene.json)",
                  { try SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0001", files: []))) },
                  satisfies: { if case SceneGraphError.missingSceneJSON = $0 { return true }; return false })
Check.throwsError("rejects invalid scene.json",
                  { try SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0009",
                                       files: [("scene.json", Data("not json".utf8))]))) },
                  satisfies: { if case SceneGraphError.invalidSceneJSON = $0 { return true }; return false })

let effectPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"image":"models/m.json","effects":[{"file":"effects/pulse/effect.json","passes":[{"combos":{"BLENDMODE":2},"constantshadervalues":{"ui_editor_properties_pulse_speed":2.9,"ui_editor_properties_tint_high":"0.9 0.8 0.7"}}]}]}]}"#.utf8)),
    ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
    ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
    ("materials/t.tex", Data("x".utf8)),
    ("effects/pulse/effect.json", Data(#"{"passes":[{"material":"materials/effects/pulse.json"}]}"#.utf8)),
    ("materials/effects/pulse.json", Data(#"{"passes":[{"shader":"effects/pulse","textures":[null,"util/noise"]}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(effectPkg), let doc = try? SceneGraph.load(from: pkg),
   let layer = doc.layers.first {
    Check.section("LayerEffect")
    Check.that("layer resolves one effect", layer.effects.count == 1)
    Check.that("effect resolves its fragment shader path", layer.effects.first?.fragmentShaderPath == "shaders/effects/pulse.frag")
    Check.that("effect is named for its folder", layer.effects.first?.name == "pulse")
    Check.that("effect captures a numeric constant", layer.effects.first?.constants["ui_editor_properties_pulse_speed"] == "2.9")
    Check.that("effect captures a vector constant", layer.effects.first?.constants["ui_editor_properties_tint_high"] == "0.9 0.8 0.7")
    Check.that("effect captures the scene's combo override", layer.effects.first?.combos["BLENDMODE"] == 2)
    Check.that("effect captures the material's sampler bindings", layer.effects.first?.textures == [nil, "util/noise"])
}

Check.section("AlphaAnimation")
let alphaAnim = AlphaAnimation(keyframes: [AlphaKeyframe(frame: 0, value: 0),
                                           AlphaKeyframe(frame: 30, value: 1),
                                           AlphaKeyframe(frame: 60, value: 0)], fps: 60, length: 120)
Check.that("alpha at t=0 is the first keyframe", alphaAnim.value(at: 0) == 0)
Check.that("alpha reaches 1 at frame 30 (0.5s)", alphaAnim.value(at: 0.5) == 1)
Check.that("alpha interpolates between keyframes", abs(alphaAnim.value(at: 0.25) - 0.5) < 0.0001)
// t=2.5 is 0.5s into the second loop (length is 2.0s), where the value is the frame-30 peak of 1.
// Clamping at the end — or any bug that just returns the first keyframe past the length — gives 0,
// so this point actually exercises that the loop maps back into the middle of the timeline.
Check.that("alpha loops into the timeline rather than clamping", alphaAnim.value(at: 2.5) == 1)
let parsedAlpha = try? SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"image":"models/m.json","alpha":{"value":1,"animation":{"c0":[{"frame":0,"value":0},{"frame":30,"value":1}],"options":{"fps":60,"length":60}}}}]}"#.utf8)),
    ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
    ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
])))
Check.that("an animated alpha is parsed onto the layer",
           parsedAlpha?.layers.first?.alphaAnimation?.keyframes.count == 2)

let posAnim = Vec3Animation(x: AlphaAnimation(keyframes: [AlphaKeyframe(frame: 0, value: 0),
                                                          AlphaKeyframe(frame: 60, value: 60)], fps: 60, length: 120),
                            y: nil, z: nil)
Check.that("position offset is zero at t=0 (motion is relative)",
           posAnim.offset(at: 0).x == 0 && posAnim.offset(at: 0).y == 0)
Check.that("position offset advances over time", abs(posAnim.offset(at: 0.5).x - 30) < 0.0001)

Check.section("ParticleSystem")
let boxParticle: [String: Any] = [
    "maxcount": 200, "material": "materials/p.json",
    "emitter": [["name": "boxrandom", "origin": "0 1024 0", "distancemax": "512 0 0", "rate": 100]],
    "initializer": [
        ["name": "lifetimerandom", "min": 1.0, "max": 2.0],
        ["name": "sizerandom", "min": 10, "max": 20],
        ["name": "velocityrandom", "min": "0 -100 0", "max": "0 -200 0"],
        ["name": "alpharandom", "min": 0.4, "max": 0.6],
    ],
    "operator": [["name": "movement", "gravity": "0 -50 0"]],
]
if let system = ParticleSystem.parse(boxParticle) {
    Check.that("parses the emitter rate and origin", system.rate == 100 && system.origin.y == 1024)
    Check.that("parses the lifetime range", system.lifetime == 1.0 ... 2.0)
    Check.that("parses the velocity range", system.velocity.min.y == -100 && system.velocity.max.y == -200)
    Check.that("parses the movement gravity", system.gravity.y == -50)
    Check.that("parses maxcount and material", system.maxCount == 200 && system.materialPath == "materials/p.json")
} else {
    Check.that("a box particle system parses", false)
}
let sphereParticle: [String: Any] = [
    "emitter": [["name": "sphererandom", "distancemax": "2000", "rate": 50, "speedmin": 0, "speedmax": 20, "directions": "1 1 0"]]
]
if let sphere = ParticleSystem.parse(sphereParticle) {
    Check.that("a sphere's scalar radius spreads across x and y", sphere.boxSize.x == 2000 && sphere.boxSize.y == 2000)
    Check.that("parses the sphere speed range", sphere.speed == 0 ... 20 && sphere.directions.x == 1)
} else {
    Check.that("a sphere particle system parses", false)
}
Check.that("rejects a system with no emitter", ParticleSystem.parse(["maxcount": 10]) == nil)
Check.that("rejects a system with a zero spawn rate",
           ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 0]]]) == nil)
// Rotation: rotationrandom gives a full-circle starting orientation; angularvelocityrandom's z is the
// screen-plane spin rate (rad/s). A system with neither leaves both ranges at zero (no spin).
let spinParticle: [String: Any] = [
    "emitter": [["name": "boxrandom", "rate": 20]],
    "initializer": [["name": "rotationrandom"], ["name": "angularvelocityrandom", "min": "0 0 -2", "max": "0 0 3"]],
]
if let spin = ParticleSystem.parse(spinParticle) {
    Check.that("rotationrandom → a full-circle initial orientation",
               spin.initialRotation.lowerBound == 0 && abs(spin.initialRotation.upperBound - 2 * .pi) < 1e-6)
    Check.that("angularvelocityrandom → the z spin-rate range", spin.angularVelocity == -2 ... 3)
}
if let plain = ParticleSystem.parse(boxParticle) {
    Check.that("a system without rotation has no spin", plain.initialRotation == 0 ... 0 && plain.angularVelocity == 0 ... 0)
    Check.that("a system without sizechange holds a constant size", plain.sizeStart == 1 && plain.sizeEnd == 1)
}
// sizechange (an operator): a size multiplier ramping over a life-fraction span.
let growParticle: [String: Any] = [
    "emitter": [["name": "boxrandom", "rate": 20]],
    "operator": [["name": "sizechange", "starttime": 0, "startvalue": 0, "endtime": 0.2, "endvalue": 1]],
]
if let grow = ParticleSystem.parse(growParticle) {
    Check.that("sizechange parses the grow-in ramp",
               grow.sizeStart == 0 && grow.sizeEnd == 1 && grow.sizeStartTime == 0 && grow.sizeEndTime == 0.2)
    Check.that("a system without alphafade is flagged so (keeps the generic fade)", grow.hasAlphaFade == false)
}
// alphafade (an operator): explicit fade-in / fade-out life fractions.
let fadeParticle: [String: Any] = [
    "emitter": [["name": "boxrandom", "rate": 20]],
    "operator": [["name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.8]],
]
if let fade = ParticleSystem.parse(fadeParticle) {
    Check.that("alphafade parses its fade-in/out fractions",
               fade.hasAlphaFade && fade.fadeInTime == 0.1 && fade.fadeOutTime == 0.8)
}
// movement drag: velocity damping in 1/s, clamped to [0,50]; absent → 0 (no damping).
if let drag = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
                                    "operator": [["name": "movement", "gravity": "0 -50 0", "drag": 2.5]]]) {
    Check.that("movement drag is parsed", drag.drag == 2.5 && drag.gravity.y == -50)
}
if let noDrag = ParticleSystem.parse(boxParticle) {
    Check.that("a system without a drag field has zero drag", noDrag.drag == 0)
}
if let bigDrag = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
                                       "operator": [["name": "movement", "drag": 9999]]]) {
    Check.that("an out-of-range drag is clamped", bigDrag.drag == 50)
}
// angularmovement: angular acceleration (z of force), clamped; absent → 0.
if let am = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
                                  "operator": [["name": "angularmovement", "force": "0 0 -1.5"]]]) {
    Check.that("angularmovement parses the z force", am.angularForce == -1.5)
}
if let plain2 = ParticleSystem.parse(boxParticle) {
    Check.that("a system without angularmovement has no angular force", plain2.angularForce == 0)
}
// oscillate operators: a sine modulator on alpha / size / position. Frequencies clamp to ≤30 Hz.
if let osc = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]], "operator": [
        ["name": "oscillatealpha", "frequencymin": 3, "frequencymax": 7, "scalemin": 0.5, "scalemax": 0.8],
        ["name": "oscillateposition", "mask": "1 0.5 0", "frequencymin": 1, "scalemin": 20, "scalemax": 35],
        ["name": "oscillatesize", "frequencymin": 999, "scalemin": 0.9, "scalemax": 1.1]]]) {
    Check.that("oscillatealpha parses freq + scale", osc.oscillateAlpha?.freq == 3...7 && osc.oscillateAlpha?.scale == 0.5...0.8)
    Check.that("oscillateposition parses its mask", osc.oscillatePosition?.mask.x == 1 && osc.oscillatePosition?.mask.y == 0.5)
    Check.that("an out-of-range oscillate frequency is clamped to 30", osc.oscillateSize?.freq.upperBound == 30)
}
if let plain3 = ParticleSystem.parse(boxParticle) {
    Check.that("a system without oscillators leaves them nil",
               plain3.oscillateAlpha == nil && plain3.oscillateSize == nil && plain3.oscillatePosition == nil)
}
// turbulentvelocityrandom (initializer): a spawn-velocity kick; scale clamped to ±100. colorchange (operator):
// tint animates start→end over a life span.
if let tv = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "initializer": [["name": "turbulentvelocityrandom", "offset": -0.5, "scale": 0.1, "speedmin": 0, "speedmax": 50]]]) {
    Check.that("turbulentvelocityrandom parses scale/offset/speed",
               tv.turbVelScale == 0.1 && tv.turbVelOffset == -0.5 && tv.turbVelSpeed == 0...50)
}
if let cc = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "colorchange", "startvalue": "1 0.75 0", "endtime": 0.8, "endvalue": "1 0 0"]]]) {
    Check.that("colorchange parses 0..1 start/end colours + endtime",
               cc.hasColorChange && cc.colorChangeStart.y == 0.75 && cc.colorChangeEnd.x == 1 && cc.colorChangeEndTime == 0.8)
}
if let plain4 = ParticleSystem.parse(boxParticle) {
    Check.that("a system without these has no turb-vel and no colorchange",
               plain4.turbVelScale == 0 && plain4.hasColorChange == false)
    Check.that("a system without turbulence leaves it nil", plain4.turbulence == nil)
}
// turbulence (operator): a noise drift; scale clamps to [0,1], timescale to [0,100].
if let tb = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "turbulence", "mask": "1 0 0", "speedmin": 25, "speedmax": 50, "scale": 0.005, "timescale": 5]]]) {
    Check.that("turbulence parses mask/speed/scale/timescale",
               tb.turbulence?.mask.x == 1 && tb.turbulence?.speed == 25...50 && tb.turbulence?.timescale == 5)
}
// controlpointattract (operator): resolves the control point's offset from the particle JSON's controlpoint
// array and parses the force/threshold.
if let cp = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "controlpoint": [["id": 1, "flags": 1, "offset": "100 50 0"]],
        "operator": [["name": "controlpointattract", "controlpoint": 1, "scale": -5000, "threshold": 64]]]) {
    Check.that("controlpointattract parses scale/threshold and the CP offset",
               cp.cpScale == -5000 && cp.cpThreshold == 64 && cp.cpOffset.x == 100 && cp.cpOffset.y == 50)
}
// vortex (operator): orbit radii/speeds; distanceouter is forced above distanceinner.
if let vx = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "vortex", "offset": "10 20 0", "distanceinner": 100, "distanceouter": 600, "speedinner": 172, "speedouter": 30]]]) {
    Check.that("vortex parses offset/radii/speeds",
               vx.vortex?.offset.x == 10 && vx.vortex?.distanceInner == 100 && vx.vortex?.distanceOuter == 600 && vx.vortex?.speedInner == 172)
}
if let plain5 = ParticleSystem.parse(boxParticle) {
    Check.that("a system without vortex/controlpoint leaves them empty", plain5.vortex == nil && plain5.cpScale == 0)
}
// Hardening: malformed/out-of-range numbers from an untrusted .pkg are clamped, never propagated.
if let hard = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20, "speedmin": 0, "speedmax": Double.infinity]],
        "initializer": [["name": "turbulentvelocityrandom", "scale": 99999, "offset": -50]],
        "operator": [["name": "alphafade", "fadeintime": -3, "fadeouttime": 9]]]) {
    Check.that("a non-finite speed is sanitised (finite range)", hard.speed.upperBound.isFinite)
    Check.that("an out-of-range turb-vel scale/offset is clamped", hard.turbVelScale == 100 && hard.turbVelOffset == -10)
    Check.that("fade in/out times clamp to [0,1]", hard.fadeInTime == 0 && hard.fadeOutTime == 1)
}

// MARK: - Done

try? fm.removeItem(at: tmpRoot)
Check.summarize()

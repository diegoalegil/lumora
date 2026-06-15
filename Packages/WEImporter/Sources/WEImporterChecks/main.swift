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
Check.that("finds all 10 item folders", itemFolders.count == 10)
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
Check.that("6 folders rejected", result.rejected.count == 6)
Check.that("'application' type rejected", reason("1004_app") == .unsupportedApplication)
Check.that("corrupt manifest rejected", isCorruptManifest(reason("1005_corrupt")))
Check.that("missing project.json rejected", reason("1006_noproj") == .missingProjectJSON)
Check.that("empty main file rejected", reason("1007_nofile") == .missingMainFile)
Check.that("missing main asset rejected", reason("1008_missingasset") == .missingMainAsset("gone.mp4"))
Check.that("unknown type rejected", reason("1009_unknown") == .unknownType("foo"))

// Direct single-folder scan also produces a diagnostic for a missing folder.
let ghost = scanner.scan(folderURL: content1.appendingPathComponent("nope"))
Check.that("scanning a folder with no project.json is a failure", {
    if case .failure(let d) = ghost, d.reason == .missingProjectJSON { return true }
    return false
}())

// MARK: - LibrarySummary

Check.section("LibrarySummary")
Check.that("summarizes the scanned library",
           LibrarySummary.line(for: result) == "4 wallpapers (2 video, 1 web, 1 scene), 6 skipped")
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
}
Check.that("SceneVec3 parses a partial string", {
    let v = SceneVec3(parsing: "1.5 2"); return v.x == 1.5 && v.y == 2 && v.z == 0
}())
Check.throwsError("rejects an empty package (no scene.json)",
                  { try SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0001", files: []))) },
                  satisfies: { if case SceneGraphError.missingSceneJSON = $0 { return true }; return false })
Check.throwsError("rejects invalid scene.json",
                  { try SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0009",
                                       files: [("scene.json", Data("not json".utf8))]))) },
                  satisfies: { if case SceneGraphError.invalidSceneJSON = $0 { return true }; return false })

Check.section("AlphaAnimation")
let alphaAnim = AlphaAnimation(keyframes: [AlphaKeyframe(frame: 0, value: 0),
                                           AlphaKeyframe(frame: 30, value: 1),
                                           AlphaKeyframe(frame: 60, value: 0)], fps: 60, length: 120)
Check.that("alpha at t=0 is the first keyframe", alphaAnim.value(at: 0) == 0)
Check.that("alpha reaches 1 at frame 30 (0.5s)", alphaAnim.value(at: 0.5) == 1)
Check.that("alpha interpolates between keyframes", abs(alphaAnim.value(at: 0.25) - 0.5) < 0.0001)
Check.that("alpha loops past the length", alphaAnim.value(at: 2.0) == 0)
let parsedAlpha = try? SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"image":"models/m.json","alpha":{"value":1,"animation":{"c0":[{"frame":0,"value":0},{"frame":30,"value":1}],"options":{"fps":60,"length":60}}}}]}"#.utf8)),
    ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
    ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
])))
Check.that("an animated alpha is parsed onto the layer",
           parsedAlpha?.layers.first?.alphaAnimation?.keyframes.count == 2)

// MARK: - Done

try? fm.removeItem(at: tmpRoot)
Check.summarize()

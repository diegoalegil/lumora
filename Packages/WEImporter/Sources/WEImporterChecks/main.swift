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

// MARK: - Parser fuzzer (on demand: `WEImporterChecks fuzz [seedDir] [iterations]`)

/// A tiny deterministic PRNG so a crash at iteration N reproduces exactly (no system randomness).
struct FuzzRNG {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(truncatingIfNeeded: next() >> 11) % n }
}

/// One of five mutations of a seed buffer, chosen by the PRNG: truncate, byte-flips, an overwritten run,
/// a giant length field (to exercise the size guards), or appended garbage.
func fuzzMutate(_ seed: Data, _ rng: inout FuzzRNG) -> Data {
    var d = [UInt8](seed)
    switch rng.below(5) {
    case 0: d = Array(d.prefix(rng.below(d.count + 1)))
    case 1: for _ in 0 ... rng.below(16) where !d.isEmpty { let i = rng.below(d.count); d[i] ^= UInt8(1 + rng.below(255)) }
    case 2: if !d.isEmpty { let i = rng.below(d.count); let v: UInt8 = rng.below(2) == 0 ? 0 : 0xFF; for k in i ..< min(d.count, i + 1 + rng.below(64)) { d[k] = v } }
    case 3: if d.count >= 4 { let i = rng.below(d.count - 3); let big: UInt32 = 0xF000_0000 | UInt32(truncatingIfNeeded: rng.next()); for b in 0 ..< 4 { d[i + b] = UInt8(truncatingIfNeeded: big >> (8 * b)) } }
    default: for _ in 0 ... rng.below(64) { d.append(UInt8(rng.below(256))) }
    }
    return Data(d)
}

/// Mutate corpus seeds and drive each untrusted parser — the .pkg reader (and SceneGraph.load on success),
/// the texture decoder, and the scene.json interpreter — looking for a trap (force-unwrap, out-of-bounds,
/// overflow) that a thrown error wouldn't catch. A clean run is evidence the parsers stay within their guards.
func runFuzz() {
    let args = CommandLine.arguments
    let fi = args.firstIndex(of: "fuzz") ?? 0
    let seedDir = args.count > fi + 1 ? args[fi + 1] : "431960"
    let iters = args.count > fi + 2 ? (Int(args[fi + 2]) ?? 200_000) : 200_000
    var pkgSeeds: [Data] = []
    var texSeeds: [Data] = []
    var jsonSeeds: [(entries: [ScenePackageEntry], idx: Int)] = []
    if let en = FileManager.default.enumerator(at: URL(fileURLWithPath: seedDir), includingPropertiesForKeys: nil) {
        for case let url as URL in en where url.lastPathComponent == "scene.pkg" {
            guard let d = try? Data(contentsOf: url) else { continue }
            pkgSeeds.append(d)
            guard let pkg = try? ScenePackage.read(d) else { continue }
            for e in pkg.entries where e.path.hasSuffix(".tex") && texSeeds.count < 80 { texSeeds.append(e.data) }
            if jsonSeeds.count < 30, let idx = pkg.entries.firstIndex(where: { $0.path.hasSuffix("scene.json") }) {
                jsonSeeds.append((pkg.entries, idx))
            }
        }
    }
    guard !pkgSeeds.isEmpty else { print("fuzz: no scene.pkg under \(seedDir)"); exit(1) }
    FileHandle.standardError.write(Data("fuzz: \(pkgSeeds.count) pkg / \(texSeeds.count) tex / \(jsonSeeds.count) json seeds, \(iters) iters\n".utf8))
    for i in 0 ..< iters {
        var rng = FuzzRNG(state: UInt64(bitPattern: Int64(i)) &* 2654435761 &+ 0x9E37_79B9_7F4A_7C15)
        switch i % 3 {
        case 0:
            if let pkg = try? ScenePackage.read(fuzzMutate(pkgSeeds[rng.below(pkgSeeds.count)], &rng)) { _ = try? SceneGraph.load(from: pkg) }
        case 1 where !texSeeds.isEmpty:
            _ = try? SceneTexture.decodeFirstMip(fuzzMutate(texSeeds[rng.below(texSeeds.count)], &rng), expandBlocks: true)
        case 2 where !jsonSeeds.isEmpty:
            let seed = jsonSeeds[rng.below(jsonSeeds.count)]
            var entries = seed.entries
            entries[seed.idx] = ScenePackageEntry(path: entries[seed.idx].path, data: fuzzMutate(entries[seed.idx].data, &rng))
            _ = try? SceneGraph.load(from: ScenePackage(version: "PKGV0001", entries: entries))
        default:
            _ = try? ScenePackage.read(fuzzMutate(pkgSeeds[rng.below(pkgSeeds.count)], &rng))
        }
        if i % 25_000 == 0 { FileHandle.standardError.write(Data("  fuzz \(i)\n".utf8)) }
    }
    print("fuzz: completed \(iters) iterations, 0 crashes/hangs")
}

if CommandLine.arguments.dropFirst().first == "fuzz" { runFuzz(); exit(0) }

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
// Generality / forward-compatibility: a FUTURE container version (one not in the sample library) must read
// like any other — the version is a label, the TOC layout is the same across the PKGV family.
Check.that("reads a future PKGV9999 version (version is a label, not a hard match)",
           (try? ScenePackage.read(buildPKG(version: "PKGV9999", files: [("scene.json", Data("{}".utf8))])))?.entry(named: "scene.json")?.data == Data("{}".utf8))
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
// A crafted package whose many TOC entries all point at the SAME blob (overlapping offset 0): every entry is
// in-bounds on its own, but copying each one would amplify a ~1 MB file into tens of MB of resident memory.
// The cumulative-size cap must reject it instead of copying past the budget.
Check.throwsError("rejects cumulative-size amplification from overlapping entries", {
    let blobSize = 1 << 20          // 1 MB blob, reused by every entry
    let entryCount = 70             // 70 × 1 MB = 70 MB copied, past the 64 MB floor
    var d = le32(8); d.append(Data("PKGV0009".utf8))
    d.append(le32(entryCount))
    for _ in 0 ..< entryCount {
        d.append(le32(1)); d.append(Data("x".utf8))    // 1-byte path
        d.append(le32(0))                              // offset 0 — every entry overlaps the same blob
        d.append(le32(blobSize))                       // size = the whole blob (in-bounds individually)
    }
    d.append(Data(count: blobSize))                    // the single shared blob
    return try ScenePackage.read(d)
}, satisfies: { if case ScenePackageError.truncated = $0 { return true }; return false })
// A legitimately large contiguous package (each blob tiles the region exactly once) stays under the cap.
Check.that("accepts a large contiguous package within the cumulative cap",
           (try? ScenePackage.read(buildPKG(version: "PKGV0009",
               files: (0 ..< 8).map { ("f\($0)", Data(count: 1 << 20)) })))?.entries.count == 8)

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
// Generality: a FUTURE .tex container/mip version reads structurally — the header layout is shared across the
// TEXV/TEXB family and the compression is inferred from the mip version number (≥3 ⇒ LZ4), not a hard match.
Check.that("reads a future TEXV9999 / TEXB9999 texture header (LZ4 inferred from the version number)",
           (try? SceneTexture.readHeader({ var d = cstr("TEXV9999"); d.append(cstr("TEXI0001")); d.append(le32(0)); d.append(le32(2)); d.append(le32(8)); d.append(le32(8)); d.append(le32(8)); d.append(le32(8)); d.append(le32(0)); d.append(cstr("TEXB9999")); d.append(le32(1)); return d }()))?.compression == TextureCompression.lz4)
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
// The content sub-rect (imageWidth/Height → uvScale = content/storage) is clamped into [1, storage]: a
// malformed .tex header with 0 (→ uvScale 0 → invisible sprite) or an oversized value must not corrupt sampling.
let clampedTex = DecodedTexture(format: .rgba8888, width: 256, height: 256, imageWidth: 0, imageHeight: 9999, pixels: Data())
Check.that("DecodedTexture clamps zero content width to 1", clampedTex.imageWidth == 1)
Check.that("DecodedTexture clamps oversized content height to storage", clampedTex.imageHeight == 256)
let okTex = DecodedTexture(format: .rgba8888, width: 256, height: 256, imageWidth: 200, imageHeight: 150, pixels: Data())
Check.that("DecodedTexture keeps a valid content rect unchanged", okTex.imageWidth == 200 && okTex.imageHeight == 150)
let rawPixels = Data((0 ..< 64).map { UInt8($0) })
if let dec = Check.noThrow("decodes a raw uncompressed mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0002", format: 0, mipW: 4, mipH: 4,
                                                    isCompressed: 0, decompressedSize: 64, payload: rawPixels))
}) {
    Check.that("raw format is RGBA8888", dec.format == .rgba8888)
    Check.that("raw mip dims", dec.width == 4 && dec.height == 4)
    Check.that("raw pixels pass through", dec.pixels == rawPixels)
}
// A POT-padded sprite: 100×100 content inside a 128×128 power-of-two buffer. decodeFirstMip must report the
// storage dims as width/height and the smaller content dims as imageWidth/imageHeight — this content/POT
// distinction is exactly what the layer compositor AND the particle sprites use (uvScale = content/storage)
// to sample only the content sub-rect of a padded texture instead of stretching it over the whole quad.
var paddedTex = buildTexHeader(format: 0, texW: 128, texH: 128, imgW: 100, imgH: 100,
                               mipContainer: "TEXB0002", mipCount: 1)
paddedTex.append(le32(0))                                              // (version 2 → one leading u32)
paddedTex.append(le32(128)); paddedTex.append(le32(128))              // mip storage dims
let paddedPayload = Data(repeating: 0, count: 128 * 128 * 4)
paddedTex.append(le32(0)); paddedTex.append(le32(paddedPayload.count)); paddedTex.append(le32(paddedPayload.count))
paddedTex.append(paddedPayload)
if let padded = Check.noThrow("decodes a POT-padded sprite", { try SceneTexture.decodeFirstMip(paddedTex) }) {
    Check.that("a padded sprite's content dims are smaller than its POT storage",
               padded.width == 128 && padded.height == 128 && padded.imageWidth == 100 && padded.imageHeight == 100)
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
// A block-compressed mip must carry one block per 4×4 region: an 8×8 BC3 needs 4 blocks = 64 bytes; a single
// 16-byte block is undersized and must be rejected by the decoder (not slip through to the GPU-upload guard).
Check.throwsError("rejects an undersized block-compressed mip", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0004", format: 4, mipW: 8, mipH: 8,
                                                    isCompressed: 0, decompressedSize: 16, payload: Data(repeating: 0xAB, count: 16)))
})
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
// A mip that decodes to MORE than one RGBA8 frame is a multi-frame texture we can't read as a single image —
// the raw and the LZ4 branches each reject it. These guards (just over one 4x4=64-byte frame, under the 256MB
// allocation bound) had no test; the boundary control (exactly one frame) must still decode.
Check.throwsError("rejects a raw mip bigger than one RGBA8 frame", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0002", format: 0, mipW: 4, mipH: 4,
                                                    isCompressed: 0, decompressedSize: 65, payload: Data(repeating: 1, count: 65)))
})
Check.that("a raw mip exactly one RGBA8 frame still decodes",
           (try? SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0002", format: 0, mipW: 4, mipH: 4,
                                                             isCompressed: 0, decompressedSize: 64, payload: Data(repeating: 1, count: 64)))) != nil)
Check.throwsError("rejects an lz4 mip whose decompressed size exceeds one RGBA8 frame", {
    try SceneTexture.decodeFirstMip(buildTexWithMip(version: "TEXB0003", format: 0, mipW: 4, mipH: 4,
                                                    isCompressed: 1, decompressedSize: 65, payload: lz4Compress(Data(repeating: 1, count: 65))))
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

// A per-object `colorBlendMode` overrides the material's `blending`. WE mode 31 is an additive glow used by
// lens flares and light "outline" layers; drawn as plain alpha-over, a full-screen glow's dark backing field
// paints over the whole scene and blacks it out (the Shinobu Kocho scene, 3265802028: an "Outline" and an
// "Artwork" object share ONE translucent material, split only by the Outline's colorBlendMode 31). So the 31
// layer must composite additive while a sibling with no override keeps the material's translucent blend.
let blendMatJSON = Data(#"{"passes":[{"blending":"translucent","shader":"genericimage4","textures":["mytex"]}]}"#.utf8)
let blendSceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},"objects":[{"name":"glow","image":"models/m.json","origin":"960 540 0","colorBlendMode":31,"visible":true},{"name":"plain","image":"models/m.json","origin":"960 540 0","visible":true}]}"#.utf8)
let blendPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", blendSceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", blendMatJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(blendPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("colorBlendMode 31 overrides a translucent material to additive",
               doc.layers.first(where: { $0.name == "glow" })?.blending == "additive")
    Check.that("an object with no colorBlendMode keeps its material's translucent blend",
               doc.layers.first(where: { $0.name == "plain" })?.blending == "translucent")
}
// Every other colorBlendMode (e.g. 2, the butterflies in that same scene) must fall through to the material's
// own blend — only the additive-glow family is remapped, so no other mode's current behaviour changes.
let cbm2SceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},"objects":[{"name":"flutter","image":"models/m.json","origin":"960 540 0","colorBlendMode":2,"visible":true}]}"#.utf8)
let cbm2Pkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", cbm2SceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", blendMatJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(cbm2Pkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a non-glow colorBlendMode keeps the material's blend",
               doc.layers.first?.blending == "translucent")
}

// A WE composition layer (models/util/{project,compose,fullscreen,effect}layer.json) carries no texture of its
// own; it reprojects/post-processes the scene through its effects, consuming the layers named in its
// `dependencies`. The importer must flag it and record the object id + dependency ids so the renderer drives it
// (rendering its dependencies → effects → recomposite) instead of skipping it as an unresolved image layer — the
// dropped "sky layers" bug (3435120596: the CloudSeamless tile feeds a projectlayer that projects it over the sky).
let compSceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},"objects":[{"id":159,"name":"CloudSeamless","image":"models/m.json","origin":"960 540 0","visible":true},{"id":43,"name":"Composition","image":"models/util/projectlayer.json","origin":"960 540 0","dependencies":[159],"visible":true}]}"#.utf8)
let compPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", compSceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(compPkg), let doc = try? SceneGraph.load(from: pkg) {
    let comp = doc.layers.first(where: { $0.name == "Composition" })
    let cloud = doc.layers.first(where: { $0.name == "CloudSeamless" })
    Check.that("a util/projectlayer object is flagged as a composition layer", comp?.isCompositionLayer == true)
    Check.that("the composition layer records its dependency ids", comp?.dependencyIDs == [159])
    Check.that("the composition layer resolves to no base texture", comp?.texturePath == nil)
    Check.that("the dependency layer's object id is captured", cloud?.objectID == 159)
    Check.that("a plain image layer is not flagged as a composition layer", cloud?.isCompositionLayer == false)
    Check.that("a plain image layer has no dependencies", cloud?.dependencyIDs == [])
}

// A layer's scale / colour / angles keyframe animations are now parsed into the IR (they were dropped to the
// base value before). Interpolation is linear — WE's per-keyframe Bezier handles aren't read yet — so this is
// the linear approximation the renderer will consume once the per-property animation path lands.
let animSceneJSON = Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},"objects":[{"name":"a","image":"models/m.json","origin":"960 540 0","scale":{"value":"1 1 0","animation":{"c0":[{"frame":0,"value":1},{"frame":60,"value":3}],"c1":[{"frame":0,"value":1},{"frame":60,"value":3}],"options":{"fps":60,"length":120,"mode":"loop"}}},"color":{"value":"1 1 1","animation":{"c0":[{"frame":0,"value":0},{"frame":60,"value":1}],"options":{"fps":60,"length":120,"mode":"loop"}}},"visible":true}]}"#.utf8)
let animPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", animSceneJSON), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(animPkg), let doc = try? SceneGraph.load(from: pkg), let layer = doc.layers.first {
    Check.that("an animated scale is parsed onto the layer (not dropped to base)", layer.scaleAnimation?.x?.keyframes.count == 2)
    Check.that("the scale animation interpolates linearly (frame 30 of 0->60, 1->3 = 2)",
               abs((layer.scaleAnimation?.x?.value(at: 0.5) ?? 0) - 2.0) < 0.0001)
    Check.that("the base scale value is still read", layer.scale.x == 1)
    Check.that("an animated colour is parsed onto the layer", layer.colorAnimation?.x?.keyframes.count == 2)
    Check.that("the colour animation interpolates linearly (0->1 at half = 0.5)",
               abs((layer.colorAnimation?.x?.value(at: 0.5) ?? -1) - 0.5) < 0.0001)
    Check.that("a layer with no angles animation leaves it nil", layer.anglesAnimation == nil)
} else {
    Check.that("animated-scale scene loads", false)
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
// A media-player widget (album-art tile, now-playing overlay, controls) drives its visibility with a script that
// stays hidden — targetAlpha 0 — until music plays (mediaPlaybackChanged / mediaThumbnailChanged). Lumora has no
// media playback, so the steady state is hidden, exactly like Wallpaper Engine with nothing playing; the layer
// must be dropped, not drawn as the static placeholder the `value:true` field reports. (A non-media visible
// script — an audio visualiser — is NOT a media widget and is kept as a driver, per the test above.)
let mediaScript = "'use strict';\\nexport function mediaPlaybackChanged(e){}\\nexport function mediaThumbnailChanged(e){ thisLayer.texture = e.texture; }\\nexport function update(){}"
let mediaScene = #"{"objects":[{"name":"albumart","image":"models/m.json","visible":{"value":true,"script":"INLINE"}}]}"#
    .replacingOccurrences(of: "INLINE", with: mediaScript)
let mediaPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(mediaScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(mediaPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a media-playback visibility widget is dropped at load (not drawn, like WE with no music)",
               doc.layers.isEmpty)
}
// A layer merely NAMED (or image-pathed) with a media-ish token but carrying NO media-event SCRIPT must NOT be
// mistaken for a now-playing widget — the detection scans bound script source only, not names/paths.
let mediaNameScene = #"{"objects":[{"name":"mediaThumbnailChanged_bg","image":"models/m.json","visible":true}]}"#
let mediaNamePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(mediaNameScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(mediaNamePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a layer named with a media token but no media script is kept (no false-positive hide)",
               doc.layers.count == 1)
}
// A now-playing widget whose VISIBILITY is ungated (no visible script — defaults shown) but whose bound
// property/text script subscribes to media events (album art tinted on mediaThumbnailChanged, a song-title
// text returning mediaData) must still be dropped: its graphic only means anything with music, so WE shows
// nothing. The layer is skipped entirely (absent from doc.layers), not merely flagged invisible.
let ungatedMediaImg = #"{"objects":[{"name":"Album Art","image":"models/m.json","alpha":{"value":1,"script":"INLINE"}}]}"#
    .replacingOccurrences(of: "INLINE", with: mediaScript)
let ungatedImgPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(ungatedMediaImg.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(ungatedImgPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("an ungated media-event image widget (album art) is dropped, not drawn",
               doc.layers.isEmpty)
}
let songTitleText = "'use strict';\\nvar mediaData='';\\nexport function update(v){ return mediaData; }\\nexport function mediaPropertiesChanged(e){ mediaData = e.title; }"
let ungatedMediaText = #"{"objects":[{"name":"Song Title","text":{"value":"Title","script":"INLINE"},"font":"fonts/f.ttf"}]}"#
    .replacingOccurrences(of: "INLINE", with: songTitleText)
let ungatedTextPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(ungatedMediaText.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(ungatedTextPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("an ungated media-event text widget (song title) is dropped, not drawn",
               doc.layers.isEmpty)
}
// An audio visualiser ("Audio Bars") often listens to mediaThumbnailChanged to tint its bars by the album art,
// yet it is NOT a now-playing widget: it reacts to the audio spectrum and collapses to nothing without music.
// It must be KEPT (registerAudioBuffers / AUDIO_RESOLUTION is the discriminator), never dropped as a media widget.
let audioVizScript = "'use strict';\\nvar b = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);\\nexport function init(){}\\nexport function mediaThumbnailChanged(e){}\\nexport function update(){ return thisLayer; }"
let audioVizScene = #"{"objects":[{"name":"Audio Bars","image":"models/m.json","scale":{"value":"1 1 1","script":"INLINE"}}]}"#
    .replacingOccurrences(of: "INLINE", with: audioVizScript)
let audioVizPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(audioVizScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(audioVizPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("an audio visualiser that only tints by mediaThumbnail is kept, not dropped",
               doc.layers.count == 1 && doc.layers.first?.driverScript?.contains("registerAudioBuffers") == true)
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
// A particle object's child sub-emitters (an ember's emberglow, a comet's trail, a magic charge's rays) are
// secondary systems WE spawns alongside the parent. Lumora collects them too, each positioned at the parent
// emitter's world origin — so a parent with one child yields TWO systems (and the child's own material/sprite).
let parentParticle = #"{"emitter":[{"name":"boxrandom","distancemax":"100 100 0","rate":50}],"material":"materials/p_parent.json","children":[{"id":1,"name":"particles/child_glow.json"}]}"#
let childParticle = #"{"emitter":[{"name":"boxrandom","distancemax":"50 50 0","rate":30}],"material":"materials/p_child.json"}"#
let childScene = #"{"objects":[{"name":"sparks","particle":"particles/parent.json","origin":"960 540 0","visible":true}]}"#
let childPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(childScene.utf8)),
    ("particles/parent.json", Data(parentParticle.utf8)),
    ("particles/child_glow.json", Data(childParticle.utf8)),
])
if let pkg = try? ScenePackage.read(childPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a particle with one child yields two systems (parent + child)", doc.particleSystems.count == 2)
    Check.that("the child system carries its own material (not the parent's)",
               doc.particleSystems.contains { $0.materialPath == "materials/p_child.json" }
               && doc.particleSystems.contains { $0.materialPath == "materials/p_parent.json" })
    Check.that("both systems sit at the parent object's world origin (960,540)",
               doc.particleSystems.allSatisfy { abs($0.origin.x - 960) < 0.01 && abs($0.origin.y - 540) < 0.01 })
}
// A childless particle still yields exactly one system (no regression from the children refactor).
let noChildScene = #"{"objects":[{"name":"sparks","particle":"particles/solo.json","origin":"0 0 0","visible":true}]}"#
let noChildPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(noChildScene.utf8)),
    ("particles/solo.json", Data(childParticle.utf8)),
])
if let pkg = try? ScenePackage.read(noChildPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a childless particle yields exactly one system", doc.particleSystems.count == 1)
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
// (an overflowing exponent parses to infinity) must fall back to the default so the glyph quads don't vanish.
let textSizePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"t","text":"Hi","pointsize":48}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(textSizePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a text layer's finite point size is kept", doc.layers.first?.pointSize == 48)
}
// A clock/label often wires its point size to a user slider, so `pointsize` is a `{ "user": …, "value": N }`
// binding rather than a bare number. The bound base value must be taken — otherwise the text collapses to the
// 32 pt default (a clock authored at 119 pt rendered tiny). Mirrors how `alpha`/`scale`/`origin` unwrap their value.
let boundSizePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"clock","text":{"value":"12:00","script":"c.js"},"pointsize":{"user":"timesize","value":119.5}}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(boundSizePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a user-bound point size takes its bound base value", doc.layers.first?.pointSize == 119.5)
}
// The author "prompt box" (visibility bound to the `promptbox` user property) is force-hidden in Lumora: it's
// an intrusive self-promo overlay that never adds to a wallpaper, so it never shows — not by the scene's
// `value` default, and not even if a saved override would turn it on. A normal `{ user, value }` visibility
// toggle still honours its default and a Customize override.
let promptPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"box","image":"models/box.json","visible":{"user":"promptbox","value":true}},{"name":"fx","image":"models/box.json","visible":{"user":"rain","value":true}}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(promptPkg) {
    let shown = try? SceneGraph.load(from: pkg)
    Check.that("the prompt box is hidden despite its value:true default", shown?.layers.first(where: { $0.name == "box" })?.visible == false)
    Check.that("a non-promptbox toggle keeps its default", shown?.layers.first(where: { $0.name == "fx" })?.visible == true)
    let forced = try? SceneGraph.load(from: pkg, overrides: ["promptbox": .bool(true)])
    Check.that("an override turning the prompt box on is ignored", forced?.layers.first(where: { $0.name == "box" })?.visible == false)
    let fxOff = try? SceneGraph.load(from: pkg, overrides: ["rain": .bool(false)])
    Check.that("a Customize override still hides a normal toggle", fxOff?.layers.first(where: { $0.name == "fx" })?.visible == false)
}
// A promptbox property the author suffixed (e.g. `promptbox2`) or wrapped in the combo form is still caught.
let promptPkg2 = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"a","image":"models/box.json","visible":{"user":"promptbox2","value":true}},{"name":"b","image":"models/box.json","visible":{"user":{"name":"PromptBox","condition":"1"},"value":true}}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(promptPkg2), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a suffixed promptbox name is hidden", doc.layers.first(where: { $0.name == "a" })?.visible == false)
    Check.that("a combo-form promptbox name is hidden", doc.layers.first(where: { $0.name == "b" })?.visible == false)
}
// Un-customised template text — a "customizable text" placeholder, a literal "Text Layer" default, or an
// author social-promo watermark — is hidden so it never gets stamped on the desktop. A real title (a stylised
// "Frieren" split into "Fri"/"eren", a "Chainsaw Man") and a scripted clock are NEVER caught.
Check.that("the CN customizable-text placeholder is junk", SceneGraph.isTemplateJunkText("（可自定义文字 Customizable text）"))
Check.that("the EN customizable-text placeholder is junk", SceneGraph.isTemplateJunkText("Customizable Text"))
Check.that("the literal Text Layer default is junk", SceneGraph.isTemplateJunkText(" Text Layer "))
Check.that("a Bilibili self-promo watermark is junk", SceneGraph.isTemplateJunkText("Bilibili/抖音 夜莺Night"))
Check.that("a real title fragment is NOT junk", !SceneGraph.isTemplateJunkText("Fri"))
Check.that("a real title is NOT junk", !SceneGraph.isTemplateJunkText("Chainsaw Man"))
Check.that("a clock string is NOT junk", !SceneGraph.isTemplateJunkText("11:56"))
let junkTextPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"ph","text":{"user":"_2","value":"（可自定义文字）"},"font":"f.ttf"},{"name":"title","text":"Frieren","font":"f.ttf"}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(junkTextPkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a placeholder text layer is hidden", doc.layers.first(where: { $0.name == "ph" })?.visible == false)
    Check.that("a real title text layer stays visible", doc.layers.first(where: { $0.name == "title" })?.visible == true)
}
// Non-boolean user properties (a colour scheme, an opacity slider, a bound point size) must reach the render
// too — without this the wallpaper shows the author's baked-in defaults, not what the user picked. A layer's
// colour/alpha/pointsize wired to `{ "user": <name>, "value": <default> }` takes the saved override of <name>.
let customPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"c","text":{"value":"12:00"},"color":{"user":"schemecolor","value":"1 1 1"},"alpha":{"user":"op","value":1},"pointsize":{"user":"sz","value":40}}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(customPkg) {
    let authored = try? SceneGraph.load(from: pkg)
    Check.that("an un-overridden colour keeps the author default", authored?.layers.first?.color.x == 1 && authored?.layers.first?.color.y == 1)
    let tuned = try? SceneGraph.load(from: pkg, overrides: ["schemecolor": .string("0.2 0.4 0.8"), "op": .number(0.5), "sz": .number(96)])
    let l = tuned?.layers.first
    Check.that("a user colour override reaches the layer colour", l?.color.x == 0.2 && l?.color.y == 0.4 && l?.color.z == 0.8)
    Check.that("a user slider override reaches the layer alpha", l?.alpha == 0.5)
    Check.that("a user slider override reaches the bound point size", l?.pointSize == 96)
}
// The scene graph is decoded strictly, so an overflowing exponent is rejected outright (unlike the particle
// ops, which go through lenient JSONSerialization and clamp ±inf). That makes the non-finite point-size clamp
// unreachable via JSON — belt-and-suspenders — so assert the ACTUAL behaviour: the document is rejected. (The
// old fixture used `1e400` and silently never ran, masking that the fallback is unexercisable from JSON.)
let badSizePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"name":"t","text":"Hi","pointsize":1e309}]}"#.utf8)),
])
Check.that("an overflowing point size is rejected by the strict scene decoder",
           ((try? ScenePackage.read(badSizePkg)).flatMap { try? SceneGraph.load(from: $0) }) == nil)
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
// A crafted scene.json can declare a PARENT CYCLE (1→2→1). The world-transform walk must terminate (its
// depth cap stops the recursion) and still place finite origins, not spin forever or overflow the stack.
let cycleScene = #"{"objects":[{"id":1,"name":"a","image":"models/m.json","parent":2,"origin":"10 0 0"},{"id":2,"name":"b","image":"models/m.json","parent":1,"origin":"0 10 0"}]}"#
let cyclePkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(cycleScene.utf8)), ("models/m.json", modelJSON),
    ("materials/mat.json", materialJSON), ("materials/mytex.tex", Data("x".utf8)),
])
if let pkg = try? ScenePackage.read(cyclePkg), let doc = try? SceneGraph.load(from: pkg) {
    Check.that("a cyclic parent chain loads without hanging and yields finite origins",
               doc.layers.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite })
} else {
    Check.that("a cyclic parent scene still loads", false)
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
// A structurally valid 80-byte-vertex .mdl whose single vertex position is a NaN bit pattern must be
// rejected (nil): a non-finite vertex would otherwise scatter/NaN its way into the renderer.
var nanMDL = Data(count: 0x74)
nanMDL[0] = 0x4d; nanMDL[1] = 0x44; nanMDL[2] = 0x4c; nanMDL[3] = 0x56          // "MDLV"
nanMDL[0x16] = 0x0f; nanMDL[0x17] = 0x00; nanMDL[0x18] = 0x80; nanMDL[0x19] = 0x01   // vertex marker
nanMDL.replaceSubrange(0x1a ..< 0x1e, with: le32(80))                          // one 80-byte vertex
nanMDL[0x1e] = 0x00; nanMDL[0x1f] = 0x00; nanMDL[0x20] = 0xc0; nanMDL[0x21] = 0x7f   // position.x = NaN
nanMDL.replaceSubrange(0x6e ..< 0x72, with: le32(2))                           // one u16 index (value 0)
Check.that("a .mdl with a NaN vertex position → nil", PuppetModel.parseMesh(nanMDL) == nil)
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

// The torn-mesh guard is the sole arbiter of whether a mesh composes: a coherent figure (skinned, or a
// near-rigid / pre-assembled flat atlas whose parts are already in place) assembles even with no decodable
// skeleton, while a scatter (parts packed far apart) is rejected so the caller keeps the preview. Build a
// minimal 80-byte-vertex .mdl with NO skeleton from explicit positions + triangles to exercise both.
@MainActor func f32bytes(_ v: Float) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
@MainActor func u16bytes(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
@MainActor func flatPuppetMDL(_ verts: [SIMD2<Float>], _ tris: [(Int, Int, Int)],
                              marker: [UInt8] = [0x0f, 0x00, 0x80, 0x01], stride: Int = 80, uvOff: Int = 72) -> Data {
    var d = Data("MDLV0099".utf8)
    while d.count < 0x15 { d.append(0) }
    d.append(0)                                   // 0x15: empty material (null terminator)
    d.append(Data(marker))                        // vertex marker
    d.append(le32(verts.count * stride))
    for v in verts {
        var vb = f32bytes(v.x); vb.append(f32bytes(v.y))     // position at byte 0/4
        while vb.count < uvOff { vb.append(0) }
        vb.append(f32bytes(0)); vb.append(f32bytes(0))       // UV at uvOff
        while vb.count < stride { vb.append(0) }
        d.append(vb)
    }
    d.append(le32(tris.count * 3 * 2))
    for (a, b, c) in tris { d.append(u16bytes(a)); d.append(u16bytes(b)); d.append(u16bytes(c)) }
    return d
}
// A compact 5×4 grid (every triangle short relative to the figure) — a coherent figure.
var gridVerts: [SIMD2<Float>] = []
for r in 0 ..< 4 { for c in 0 ..< 5 { gridVerts.append(SIMD2(Float(c * 10), Float(r * 10))) } }
var gridTris: [(Int, Int, Int)] = []
for r in 0 ..< 3 { for c in 0 ..< 4 { let i = r * 5 + c; gridTris.append((i, i + 1, i + 5)); gridTris.append((i + 1, i + 6, i + 5)) } }
Check.that("a coherent flat atlas with no skeleton assembles (drawn as-is)",
           PuppetModel.parseMesh(flatPuppetMDL(gridVerts, gridTris))?.assembled == true)
// Two tight clusters 10000 apart, every triangle bridging them — a scatter the torn guard must reject.
let scatterVerts: [SIMD2<Float>] = [
    SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10), SIMD2(10, 10),
    SIMD2(10000, 0), SIMD2(10010, 0), SIMD2(10000, 10), SIMD2(10010, 10),
]
var scatterTris: [(Int, Int, Int)] = []
for k in 0 ..< 12 { scatterTris.append((k % 4, 4 + (k % 4), (k + 1) % 4)) }
Check.that("a scattered atlas (parts packed far apart) is rejected as torn",
           PuppetModel.parseMesh(flatPuppetMDL(scatterVerts, scatterTris))?.assembled == false)
// The compact 52-byte vertex also ships under a `0e 00 81 01` marker (not only `09 00 80 01`); both decode
// the same way (position at 0/4, UV at 44). A coherent grid in that form must parse and compose.
Check.that("the 0e 00 81 01 compact-vertex marker is recognised (52-byte stride)",
           PuppetModel.parseMesh(flatPuppetMDL(gridVerts, gridTris, marker: [0x0e, 0x00, 0x81, 0x01], stride: 52, uvOff: 44))?.assembled == true)
// The SAME `0e 00 81 01` marker also ships as an 84-byte vertex (a normal/tangent block; the MDLV0023 model
// in scene 3577990983 / "Reze"). The marker byte alone doesn't fix the stride, so the parser must pick the
// candidate stride that evenly divides the declared vertex-block size — here 84, not 52 — and compose it.
Check.that("the 0e 00 81 01 marker also resolves as an 84-byte vertex (stride disambiguated by block size)",
           PuppetModel.parseMesh(flatPuppetMDL(gridVerts, gridTris, marker: [0x0e, 0x00, 0x81, 0x01], stride: 84, uvOff: 76))?.assembled == true)
// When a vertex-block size divides evenly by BOTH candidate strides (a 13-vertex 84-byte rig: 13*84 = 1092
// is also divisible by 52), the parser must not commit to the first divisor (52). It tries 52, finds it
// doesn't compose, and falls back to 84. To make the 52 attempt fail cleanly, plant a NaN in each 84-byte
// vertex's normal block (byte 52 — ignored at stride 84) which lands on a *position* x/y under the wrong
// 52-byte stride, so the finite-float guard rejects the 52 parse and only the 84 parse composes.
var verts13: [SIMD2<Float>] = []
for i in 0 ..< 13 { verts13.append(SIMD2(Float((i % 5) * 10), Float((i / 5) * 10))) }
var tris13: [(Int, Int, Int)] = []
for c in 0 ..< 4 { tris13.append((c, c + 1, c + 5)); tris13.append((c + 1, c + 6, c + 5)) }       // rows 0–1
for c in 0 ..< 2 { tris13.append((5 + c, 6 + c, 10 + c)); tris13.append((6 + c, 11 + c, 10 + c)) } // rows 1–2
var collide = flatPuppetMDL(verts13, tris13, marker: [0x0e, 0x00, 0x81, 0x01], stride: 84, uvOff: 76)
// vertexBase = 30 (MDLV0099 + pad to 0x15 + null material + 4-byte marker + 4-byte size); vertex-local byte 52.
let nanBytes = f32bytes(.nan)
for k in 0 ..< 13 { let o = 30 + k * 84 + 52; collide.replaceSubrange(o ..< o + 4, with: nanBytes) }
Check.that("a 0e marker whose block divides by both strides falls back from 52 to the composing 84",
           PuppetModel.parseMesh(collide)?.assembled == true)
// A vertex marker the version→layout table doesn't know (here a made-up `05 00 80 01`) must degrade to nil —
// the caller keeps the preview — never crash or guess a layout.
Check.that("an unknown vertex marker → nil (graceful, no crash)",
           PuppetModel.parseMesh(flatPuppetMDL(gridVerts, gridTris, marker: [0x05, 0x00, 0x80, 0x01])) == nil)
// A markerless version (MDLV0013 — no `XX 00 8x 01` marker) is recognised by default now its rig was
// signed off (the LUMORA_PUPPET_V13 gate was dropped). This crafted one carries an EMPTY vertex block, so
// it degrades to nil via the `vertexBytes > 0` bounds guard rather than the old gate — never crashing.
var mdl13 = Data("MDLV0013".utf8); while mdl13.count < 0x40 { mdl13.append(0) }
Check.that("a markerless MDLV0013 with an empty vertex block degrades to nil (bounds guard)",
           PuppetModel.parseMesh(mdl13) == nil)

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
    ("scene.json", Data(#"{"objects":[{"image":"models/m.json","effects":[{"file":"effects/pulse/effect.json","passes":[{"combos":{"BLENDMODE":2},"constantshadervalues":{"ui_editor_properties_pulse_speed":2.9,"ui_editor_properties_tint_high":"0.9 0.8 0.7","ui_editor_properties_tint_low":{"user":"newprop","value":"0.1 0.2 0.3"}}}]}]}]}"#.utf8)),
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
    // A user-property-bound constant `{ "user": …, "value": … }` must be unwrapped to its value, not dropped
    // (dropping it falls the effect back to its shader default — e.g. a tint bg washing red, scene 3195212886).
    Check.that("effect unwraps a user-bound constant to its value", layer.effects.first?.constants["ui_editor_properties_tint_low"] == "0.1 0.2 0.3")
    Check.that("effect captures the scene's combo override", layer.effects.first?.combos["BLENDMODE"] == 2)
    Check.that("effect captures the material's sampler bindings", layer.effects.first?.textures == [nil, "util/noise"])
}
// The viewer's Customize override of that user-bound constant must win over the author's default value, so a
// re-tinted effect (the user's colour scheme) reaches the shader instead of the baked-in default.
if let pkg = try? ScenePackage.read(effectPkg),
   let tuned = try? SceneGraph.load(from: pkg, overrides: ["newprop": .string("0.8 0.7 0.95")]).layers.first {
    Check.that("a user override of an effect constant wins over the author default",
               tuned.effects.first?.constants["ui_editor_properties_tint_low"] == "0.8 0.7 0.95")
}
// An effect toggled off by a user property (`visible:{value:false}`, or a bare `false`) is disabled by default
// in Wallpaper Engine — applied only when the user enables it. Lumora has no UI to flip it, so a default-off
// effect must be SKIPPED (not rendered), matching WE's fresh-load state; an always-on (`true`/missing/`{value:true}`)
// effect is kept. Two effects on one layer, one off, exercises the filter precisely.
let effVisScene = #"{"objects":[{"image":"models/m.json","effects":[{"file":"effects/pulse/effect.json","visible":{"user":"glow","value":false},"passes":[{}]},{"file":"effects/pulse/effect.json","visible":{"user":"grade","value":true},"passes":[{}]},{"file":"effects/pulse/effect.json","visible":false,"passes":[{}]},{"file":"effects/pulse/effect.json","passes":[{}]}]}]}"#
let effVisPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(effVisScene.utf8)),
    ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
    ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
    ("materials/t.tex", Data("x".utf8)),
    ("effects/pulse/effect.json", Data(#"{"passes":[{"material":"materials/effects/pulse.json"}]}"#.utf8)),
    ("materials/effects/pulse.json", Data(#"{"passes":[{"shader":"effects/pulse","textures":["t"]}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(effVisPkg), let doc = try? SceneGraph.load(from: pkg), let layer = doc.layers.first {
    // Of the 4 effects: glow {value:false} skipped, grade {value:true} kept, bare false skipped, bare-absent kept → 2.
    Check.that("default-off effects (visible.value:false / bare false) are skipped, always-on kept (2 of 4)",
               layer.effects.count == 2)
    // The viewer's Customize override of the user property wins, symmetric with layer visibility: turning `glow`
    // ON adds its effect (3 of 4), and turning the default-on `grade` OFF removes it.
    if let on = try? SceneGraph.load(from: pkg, overrides: ["glow": .bool(true)]).layers.first {
        Check.that("a Customize override turns a default-off effect on (3 of 4)", on.effects.count == 3)
    }
    if let off = try? SceneGraph.load(from: pkg, overrides: ["grade": .bool(false)]).layers.first {
        Check.that("a Customize override turns a default-on effect off (1 of 4)", off.effects.count == 1)
    }
}
// An effect's FBO downscale factor comes from untrusted effect.json and must land in the 1…16 the renderer
// actually allocates — a 0 would size a zero/divide-by-zero buffer, a huge value would over-allocate. Pin the
// clamp (no fbos appear in the effect above, so this is otherwise unexercised).
let fboPkg = buildPKG(version: "PKGV0009", files: [
    ("scene.json", Data(#"{"objects":[{"image":"models/m.json","effects":[{"file":"effects/pulse/effect.json","passes":[{}]}]}]}"#.utf8)),
    ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
    ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
    ("effects/pulse/effect.json", Data(#"{"passes":[{"material":"materials/effects/pulse.json"}],"fbos":[{"name":"under","scale":0},{"name":"over","scale":1000},{"name":"ok","scale":4}]}"#.utf8)),
    ("materials/effects/pulse.json", Data(#"{"passes":[{"shader":"effects/pulse","textures":["t"]}]}"#.utf8)),
])
if let pkg = try? ScenePackage.read(fboPkg), let doc = try? SceneGraph.load(from: pkg),
   let fbos = doc.layers.first?.effects.first?.fbos {
    Check.that("effect FBO scales clamp into the renderer's 1…16 range",
               fbos.count == 3 && fbos[0].scale == 1 && fbos[1].scale == 16 && fbos[2].scale == 4)
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
// WE's `single` mode plays a curve once and HOLDS the last keyframe; only `loop` mode wraps. A one-shot
// 0→1 fade-in over [0,90]@30fps (length 90 = 3.0s) must read 1 (held) past its end when single, but a
// looping one snaps back to its first value at every multiple of the length.
let singleFade = AlphaAnimation(keyframes: [AlphaKeyframe(frame: 0, value: 0), AlphaKeyframe(frame: 90, value: 1)],
                                fps: 30, length: 90, isLooping: false)
Check.that("a single (play-once) animation holds its last value past length",
           singleFade.value(at: 3.0) == 1 && singleFade.value(at: 6.0) == 1)
let loopFade = AlphaAnimation(keyframes: [AlphaKeyframe(frame: 0, value: 0), AlphaKeyframe(frame: 90, value: 1)],
                              fps: 30, length: 90, isLooping: true)
Check.that("a looping animation wraps back to its first value at length", loopFade.value(at: 3.0) == 0)
// The looping flag is read from the animation's options.mode at parse time.
@MainActor func parseAlphaMode(_ mode: String) -> AlphaAnimation? {
    let json = "{\"objects\":[{\"image\":\"models/m.json\",\"alpha\":{\"value\":1,\"animation\":{\"c0\":[{\"frame\":0,\"value\":0},{\"frame\":90,\"value\":1}],\"options\":{\"fps\":30,\"length\":90,\"mode\":\"\(mode)\"}}}}]}"
    return (try? SceneGraph.load(from: ScenePackage.read(buildPKG(version: "PKGV0009", files: [
        ("scene.json", Data(json.utf8)),
        ("models/m.json", Data(#"{"material":"materials/mat.json"}"#.utf8)),
        ("materials/mat.json", Data(#"{"passes":[{"textures":["t"]}]}"#.utf8)),
    ]))))?.layers.first?.alphaAnimation
}
Check.that("parse reads mode:single as a non-looping (held) animation", parseAlphaMode("single")?.value(at: 6.0) == 1)
Check.that("parse reads mode:loop as a looping animation", parseAlphaMode("loop")?.value(at: 3.0) == 0)

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
// A boxrandom emitter with NO distancemax adopts the scene half-extents as its spawn box, so its sprites spread
// across the wallpaper like Wallpaper Engine instead of piling into a dense blob at the emitter origin.
let noBoxEmitter: [String: Any] = ["emitter": [["name": "boxrandom", "rate": 50]]]
if let s = ParticleSystem.parse(noBoxEmitter, sceneBox: SceneVec3(x: 960, y: 540, z: 0)) {
    Check.that("boxrandom without distancemax adopts the scene box", s.boxSize.x == 960 && s.boxSize.y == 540)
}
if let s0 = ParticleSystem.parse(noBoxEmitter) {
    Check.that("boxrandom without distancemax or a scene box stays a point (back-compat)", s0.boxSize.x == 0 && s0.boxSize.y == 0)
}
if let s2 = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 50, "distancemax": "100 80 0"]]],
                                  sceneBox: SceneVec3(x: 960, y: 540, z: 0)) {
    Check.that("an explicit box distancemax overrides the scene-box default", s2.boxSize.x == 100 && s2.boxSize.y == 80)
}
// A sphere emitter's distancemax is a bare JSON NUMBER (this is how the real library encodes it), not a
// string — the parse must read the scalar radius and spread it across x/y, not drop it to zero.
let sphereParticle: [String: Any] = [
    "emitter": [["name": "sphererandom", "distancemax": 2000, "rate": 50, "speedmin": 0, "speedmax": 20, "directions": "1 1 0"]]
]
if let sphere = ParticleSystem.parse(sphereParticle) {
    Check.that("a sphere's numeric scalar radius spreads across x and y", sphere.boxSize.x == 2000 && sphere.boxSize.y == 2000)
    Check.that("parses the sphere speed range", sphere.speed == 0 ... 20 && sphere.directions.x == 1)
} else {
    Check.that("a sphere particle system parses", false)
}
// A non-finite scalar distancemax (inf/NaN, reachable via -1e309 etc. through JSONSerialization) must be
// sanitised like every other untrusted scalar — never reach the spawn math as inf/NaN.
if let s = ParticleSystem.parse(["emitter": [["name": "sphererandom", "distancemax": Double.infinity, "rate": 50]]]) {
    Check.that("a non-finite sphere distancemax is clamped finite", s.boxSize.x.isFinite && s.boxSize.y.isFinite)
}
if let b = ParticleSystem.parse(["emitter": [["name": "boxrandom", "distancemax": Double.nan, "rate": 50]]]) {
    Check.that("a NaN box distancemax is clamped finite", b.boxSize.x.isFinite && b.boxSize.y.isFinite)
}
// A vortex operator's distances/speeds from untrusted JSON must be sanitised finite too (a non-finite radius
// would feed the renderer's orbit math a NaN and scatter sprites) — like the attractor/oscillator scalars.
if let vtx = ParticleSystem.parse(["emitter": [["name": "boxrandom", "distancemax": "10 10 0", "rate": 50]],
                                   "operator": [["name": "vortex", "distanceinner": Double.infinity,
                                                 "distanceouter": Double.infinity, "speedinner": Double.infinity,
                                                 "speedouter": Double.nan]]]),
   let v = vtx.vortex {
    Check.that("vortex distances/speeds are clamped finite",
               v.distanceInner.isFinite && v.distanceOuter.isFinite && v.speedInner.isFinite && v.speedOuter.isFinite)
    Check.that("vortex outer stays > inner after clamping", v.distanceOuter > v.distanceInner)
}
Check.that("rejects a system with no emitter", ParticleSystem.parse(["maxcount": 10]) == nil)
Check.that("rejects a system with a zero spawn rate",
           ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 0]]]) == nil)
// Format coverage: an unknown initializer/operator name (a future or unseen WE feature) must be skipped,
// not break parsing — the rest of the system still loads and the emitter still spawns.
let unknownOpParticle: [String: Any] = [
    "emitter": [["name": "boxrandom", "rate": 20]],
    "initializer": [["name": "somefutureinitializer", "min": 1, "max": 2], ["name": "sizerandom", "min": 5, "max": 6]],
    "operator": [["name": "somefutureoperator", "x": 1], ["name": "movement", "gravity": "0 -9 0"]],
]
if let sys = ParticleSystem.parse(unknownOpParticle) {
    Check.that("an unknown initializer/operator is skipped, the system still parses", sys.rate == 20)
    Check.that("a known operator beside an unknown one still applies", sys.gravity.y == -9 && sys.size == 5 ... 6)
}
// An oscillate* operator's phase/scale come from untrusted JSON. A non-finite value (inf) must be clamped
// at parse so sin(phase) can't go NaN and fling a sprite to a non-finite position — i.e. never a scatter.
let infOscParticle: [String: Any] = [
    "emitter": [["name": "boxrandom", "rate": 20]],
    "operator": [["name": "oscillateposition", "phasemin": Double.infinity, "phasemax": Double.infinity,
                  "scalemin": -Double.infinity, "scalemax": Double.infinity, "frequencymax": Double.infinity, "mask": "1 1 0"]],
]
if let osc = ParticleSystem.parse(infOscParticle), let o = osc.oscillatePosition {
    Check.that("a non-finite oscillator phase is clamped finite", o.phase.lowerBound.isFinite && o.phase.upperBound.isFinite)
    Check.that("a non-finite oscillator scale is clamped finite", o.scale.lowerBound.isFinite && o.scale.upperBound.isFinite)
    Check.that("a non-finite oscillator frequency is clamped finite", o.freq.lowerBound.isFinite && o.freq.upperBound.isFinite)
} else {
    Check.that("an oscillateposition system parses", false)
}
// A negative-overflow frequency bound (JSONSerialization accepts -1e309 → -inf) maps to the finite default
// AFTER ordering — a non-finite lower bound combined with a small finite upper bound must NOT build an
// inverted range (1 ... 0.5) that traps ClosedRange.init. Parsing must not crash and the range stays ordered.
if let osc = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "oscillatealpha", "frequencymin": -Double.infinity, "frequencymax": 0.5]]]),
   let o = osc.oscillateAlpha {
    Check.that("an inverted-after-clamp oscillator frequency stays a well-ordered finite range",
               o.freq.lowerBound.isFinite && o.freq.upperBound.isFinite && o.freq.lowerBound <= o.freq.upperBound)
} else {
    Check.that("an oscillatealpha system with a non-finite frequency parses without trapping", false)
}
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
// rotationrandom honours shipped bounds: a scalar pair, and the z of an "x y z" vector pair.
if let rScalar = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 5]],
        "initializer": [["name": "rotationrandom", "min": -0.4, "max": -0.3]]]) {
    Check.that("rotationrandom honours scalar min/max bounds",
               abs(rScalar.initialRotation.lowerBound - (-0.4)) < 1e-6 && abs(rScalar.initialRotation.upperBound - (-0.3)) < 1e-6)
}
if let rVec = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 5]],
        "initializer": [["name": "rotationrandom", "min": "0 0 0", "max": "0 0 1.5"]]]) {
    Check.that("rotationrandom reads the z of an x-y-z vector bound",
               rVec.initialRotation.lowerBound == 0 && abs(rVec.initialRotation.upperBound - 1.5) < 1e-6)
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
// A non-finite sizechange value (reachable via -1e309 → -inf through JSONSerialization) must be clamped, or it
// lerps to NaN/Inf and reaches the GPU as a non-finite sprite size. Build via the real loader path.
if let j = try? JSONSerialization.jsonObject(with: Data(#"{"emitter":[{"name":"boxrandom","rate":20}],"operator":[{"name":"sizechange","startvalue":-1e309,"endvalue":1}]}"#.utf8)) as? [String: Any],
   let nf = ParticleSystem.parse(j) {
    Check.that("a non-finite sizechange value is clamped finite", nf.sizeStart.isFinite && nf.sizeEnd.isFinite)
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
    Check.that("a single controlpointattract yields exactly one attractor", cp.attractors.count == 1)
}
// Multiple controlpointattract operators (a real corpus pattern — e.g. workshop "birds": a short-range repel
// + a long-range attract on the same point) must ALL be captured. Previously only the LAST survived (the
// parser overwrote scalar fields), silently dropping the others; now they accumulate for the renderer to sum.
if let cp2 = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "controlpoint": [["id": 1, "offset": "0 -9999 0"], ["id": 2, "offset": "1500 0 0"]],
        "operator": [
            ["name": "controlpointattract", "controlpoint": 1, "scale": -600, "threshold": 50],
            ["name": "controlpointattract", "controlpoint": 2, "scale": 500, "threshold": 5000]]]) {
    Check.that("both controlpointattract operators are captured (not last-write-wins)", cp2.attractors.count == 2)
    Check.that("the first attractor keeps its own scale/threshold/offset",
               cp2.attractors[0].scale == -600 && cp2.attractors[0].threshold == 50 && cp2.attractors[0].offset.y == -9999)
    Check.that("the second attractor resolves a DIFFERENT control point",
               cp2.attractors[1].scale == 500 && cp2.attractors[1].threshold == 5000 && cp2.attractors[1].offset.x == 1500)
}
// Hardening: a crafted .pkg cannot accumulate an unbounded attractor array (cap 16).
if let cpFlood = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "controlpoint": [["id": 1, "offset": "0 0 0"]],
        "operator": Array(repeating: ["name": "controlpointattract", "controlpoint": 1, "scale": 100, "threshold": 64], count: 64)]) {
    Check.that("the attractor array is capped against a flood", cpFlood.attractors.count == 16)
}
// vortex (operator): orbit radii/speeds; distanceouter is forced above distanceinner.
if let vx = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "vortex", "offset": "10 20 0", "distanceinner": 100, "distanceouter": 600, "speedinner": 172, "speedouter": 30]]]) {
    Check.that("vortex parses offset/radii/speeds",
               vx.vortex?.offset.x == 10 && vx.vortex?.distanceInner == 100 && vx.vortex?.distanceOuter == 600 && vx.vortex?.speedInner == 172)
}
// A crafted .pkg can set the outer radius below the inner; the parser forces it to at least inner + 1 so the
// orbit band never inverts. The normal case above never exercises that clamp (600 > 100), so pin it here.
if let vxBad = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20]],
        "operator": [["name": "vortex", "offset": "0 0 0", "distanceinner": 100, "distanceouter": 50]]]) {
    Check.that("vortex outer radius is forced above the inner radius",
               vxBad.vortex?.distanceInner == 100 && vxBad.vortex?.distanceOuter == 101)
}
if let plain5 = ParticleSystem.parse(boxParticle) {
    Check.that("a system without vortex/controlpoint leaves them empty",
               plain5.vortex == nil && plain5.cpScale == 0 && plain5.attractors.isEmpty)
}
// Hardening: malformed/out-of-range numbers from an untrusted .pkg are clamped, never propagated.
if let hard = ParticleSystem.parse(["emitter": [["name": "boxrandom", "rate": 20, "speedmin": 0, "speedmax": Double.infinity]],
        "initializer": [["name": "turbulentvelocityrandom", "scale": 99999, "offset": -50]],
        "operator": [["name": "alphafade", "fadeintime": -3, "fadeouttime": 9]]]) {
    Check.that("a non-finite speed is sanitised (finite range)", hard.speed.upperBound.isFinite)
    Check.that("an out-of-range turb-vel scale/offset is clamped", hard.turbVelScale == 100 && hard.turbVelOffset == -10)
    Check.that("fade in/out times clamp to [0,1]", hard.fadeInTime == 0 && hard.fadeOutTime == 1)
}

// MARK: - Camerapath bézier track
do {
    // Default handles — front (1/3,1/3), back (-1/3,-1/3) — put the cubic-bézier control points on the y=x
    // diagonal, i.e. exactly linear, so a 0→100 track's midpoint is 50.
    let lin = WEBezierTrack(keys: [WEBezierKey(frame: 0, value: 0), WEBezierKey(frame: 10, value: 100)],
                            fps: 10, length: 0, isLooping: false)
    Check.that("bézier default handles interpolate linearly (midpoint = 50)", abs(lin.value(at: 0.5) - 50) < 0.05)
    Check.that("bézier holds the first keyframe before its frame", lin.value(at: -1) == 0)
    Check.that("bézier holds the last keyframe after its frame", lin.value(at: 100) == 100)
    Check.that("bézier is monotonic on a rising track", lin.value(at: 0.2) < lin.value(at: 0.8))
    let one = WEBezierTrack(keys: [WEBezierKey(frame: 5, value: 7)], fps: 10, length: 0, isLooping: false)
    Check.that("a single-key bézier track holds its value", one.value(at: 0) == 7 && one.value(at: 100) == 7)
    // Mirrors 3675966045's zoom track: held at 2.13 before the first key, settling to 1.0 after the last.
    let zoom = WEBezierTrack(keys: [WEBezierKey(frame: 18, value: 2.13), WEBezierKey(frame: 70, value: 1.0)],
                             fps: 22.5, length: 90, isLooping: false)
    Check.that("camera zoom holds 2.13 before the first key", abs(zoom.value(at: 0) - 2.13) < 1e-6)
    Check.that("camera zoom settles to 1.0 after the last key", abs(zoom.value(at: 8) - 1.0) < 1e-6)
    let staticCam = SceneCameraPath(baseX: 0, baseY: 0, relative: true, trackX: nil, trackY: nil, zoomTrack: nil)
    Check.that("a track-less camera path is not animated", !staticCam.isAnimated)
    Check.that("a track-less camera path is identity (no pan, unit zoom)",
               staticCam.offset(at: 1).x == 0 && staticCam.zoom(at: 1) == 1)
}

// MARK: - P4 regression guards: dict-form general defaults + solid-layer model detection
do {
    func mk(_ sceneJSON: String, _ extra: [String: String] = [:]) -> RenderableScene? {
        var entries = [ScenePackageEntry(path: "scene.json", data: Data(sceneJSON.utf8))]
        for (p, j) in extra { entries.append(ScenePackageEntry(path: p, data: Data(j.utf8))) }
        return try? SceneGraph.load(from: ScenePackage(version: "PKGV0001", entries: entries))
    }
    // general.bloom as a {user,value} binding must be honoured, not read as off.
    Check.that("general.bloom {user,value:true} dict turns bloom on",
               (mk(#"{"general":{"bloom":{"user":"x","value":true},"bloomstrength":0.5},"objects":[]}"#)?.bloomStrength ?? 0) > 0)
    Check.that("general.bloom {value:false} dict keeps bloom off",
               (mk(#"{"general":{"bloom":{"value":false},"bloomstrength":0.5},"objects":[]}"#)?.bloomStrength ?? -1) == 0)
    Check.that("general.bloom plain Bool true still on",
               (mk(#"{"general":{"bloom":true,"bloomstrength":0.5},"objects":[]}"#)?.bloomStrength ?? 0) > 0)
    // generalNumber resolves dict-form numeric fields.
    if let z = mk(#"{"general":{"zoom":{"value":1.5}},"objects":[]}"#)?.zoom {
        Check.that("general.zoom {value:1.5} dict resolves", abs(z - 1.5) < 1e-6)
    } else { Check.that("zoom-dict scene loads", false) }
    if let st = mk(#"{"general":{"bloom":true,"bloomstrength":{"value":3.0}},"objects":[]}"#)?.bloomStrength {
        Check.that("general.bloomstrength {value:3.0} dict resolves", abs(st - 3.0) < 1e-6)
    } else { Check.that("strength-dict scene loads", false) }
    // solid-colour layer detected via the model's solidlayer FLAG alone — material path has no "solidlayer"
    // substring and neither does the image path, so only the flag branch can make this pass.
    let model = #"{"solidlayer":true,"material":"materials/util/plain.json"}"#
    let scene = #"{"general":{},"objects":[{"id":1,"name":"bg","image":"models/solid_x.json","color":"1 0 0"}]}"#
    if let r = mk(scene, ["models/solid_x.json": model]) {
        Check.that("solid layer detected via model solidlayer flag (material has no 'solidlayer' substring)",
                   r.layers.contains { $0.isSolidLayer })
    } else { Check.that("solid-layer (flag) scene loads", false) }
    // and via the material path alone — no flag, image path has no "solidlayer", only the material branch fires.
    let matModel = #"{"material":"materials/util/solidlayer_instance.json"}"#
    let matScene = #"{"general":{},"objects":[{"id":1,"name":"bg","image":"models/m_x.json","color":"1 0 0"}]}"#
    if let r = mk(matScene, ["models/m_x.json": matModel]) {
        Check.that("solid layer detected via solidlayer MATERIAL path (no flag)", r.layers.contains { $0.isSolidLayer })
    } else { Check.that("solid-layer (material) scene loads", false) }
    // a normal image layer (no solidlayer flag) is NOT a solid fill.
    let plainModel = #"{"material":"materials/foo.json"}"#
    let plainScene = #"{"general":{},"objects":[{"id":1,"name":"img","image":"models/foo.json"}]}"#
    if let r = mk(plainScene, ["models/foo.json": plainModel]) {
        Check.that("plain image layer is not flagged solid", !(r.layers.first?.isSolidLayer ?? true))
    } else { Check.that("plain-layer scene loads", false) }
}

// MARK: - Done

try? fm.removeItem(at: tmpRoot)
runBCBlockChecks()
runParticleDoSChecks()
Check.summarize()

// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Reader for Wallpaper Engine's "PKGV" scene.pkg container, reverse-confirmed
// from the on-disk byte layout of the user's OWN packages: a length-prefixed "PKGV00xx" label, a
// little-endian table of contents of [nameLen][utf8 path][offset][size] entries, then one contiguous
// data-blob region (entry bytes live at blobBase + offset). No GPL source was consulted.
import Foundation

/// One file packed inside a `scene.pkg`: its in-package path and raw bytes.
public struct ScenePackageEntry: Sendable, Equatable {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Why a `scene.pkg` could not be read.
public enum ScenePackageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer bytes than even an empty header needs.
    case tooSmall
    /// The label isn't a `PKGV…` signature (not a scene package).
    case badSignature(String)
    /// The header or table of contents runs past the end of the data.
    case truncated
    /// A table-of-contents entry points outside the data-blob region.
    case entryOutOfBounds(path: String)

    public var description: String {
        switch self {
        case .tooSmall:                  return "scene.pkg is too small to be valid"
        case .badSignature(let s):       return "not a PKGV scene package (signature '\(s)')"
        case .truncated:                 return "scene.pkg header/TOC is truncated"
        case .entryOutOfBounds(let p):   return "scene.pkg entry '\(p)' points outside the data region"
        }
    }
}

/// A parsed Wallpaper Engine `scene.pkg` container: its version label and the files it packs, in the
/// order the table of contents lists them. The renderer reads `scene.json` plus the referenced
/// textures/shaders out of here; this type only *unpacks* — it does not interpret the scene.
public struct ScenePackage: Sendable, Equatable {
    /// The version label exactly as written on disk, e.g. `"PKGV0009"`. Across every observed package
    /// the digits are only a label — the header/TOC layout is identical — so one reader covers them.
    public let version: String
    /// Packed files in table-of-contents order. `scene.json` is conventionally the first entry.
    public let entries: [ScenePackageEntry]

    public init(version: String, entries: [ScenePackageEntry]) {
        self.version = version
        self.entries = entries
    }

    /// The first entry whose path equals `name` (case-insensitively), if present.
    public func entry(named name: String) -> ScenePackageEntry? {
        entries.first { $0.path.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The scene graph document: the `scene.json` entry, falling back to the first entry (where WE
    /// places it).
    public var sceneJSON: ScenePackageEntry? {
        entry(named: "scene.json") ?? entries.first
    }

    /// Read and parse a `scene.pkg` from a file on disk.
    public static func read(contentsOf url: URL) throws -> ScenePackage {
        try read(Data(contentsOf: url))
    }

    /// Parse a `scene.pkg` from its raw bytes.
    public static func read(_ data: Data) throws -> ScenePackage {
        guard data.count >= 8 else { throw ScenePackageError.tooSmall }
        let base = data.startIndex
        var cursor = 0

        func u32() throws -> Int {
            guard cursor + 4 <= data.count else { throw ScenePackageError.truncated }
            let i = base + cursor
            let value = UInt32(data[i]) | UInt32(data[i + 1]) << 8
                | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            cursor += 4
            return Int(value)
        }
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, cursor + count <= data.count else { throw ScenePackageError.truncated }
            let start = base + cursor
            cursor += count
            return data.subdata(in: start ..< start + count)
        }
        // A length-prefixed UTF-8 string (the signature and every TOC path use this shape).
        func lpString() throws -> String {
            let length = try u32()
            return String(decoding: try bytes(length), as: UTF8.self)
        }

        let version = try lpString()
        guard version.hasPrefix("PKGV") else { throw ScenePackageError.badSignature(version) }

        let count = try u32()
        guard count >= 0, count <= data.count / 4 else { throw ScenePackageError.truncated }

        var table: [(path: String, offset: Int, size: Int)] = []
        // `count` is only bounded by data.count/4, but each entry occupies ≥12 bytes, so reserving `count`
        // could pre-allocate many times the file size for a crafted .pkg. Cap the hint; the loop below still
        // throws cleanly if the declared count outruns the data.
        table.reserveCapacity(min(count, 4096))
        for _ in 0 ..< count {
            let path = try lpString()
            let offset = try u32()
            let size = try u32()
            table.append((path, offset, size))
        }

        // The data-blob region begins right after the table of contents; entry offsets are relative
        // to it.
        let blobBase = cursor
        var entries: [ScenePackageEntry] = []
        entries.reserveCapacity(min(count, 4096))
        // The per-entry bounds check confirms each blob lies inside the file, but entry offsets may overlap, so
        // it does not bound the TOTAL bytes copied: a crafted .pkg whose many entries all point at one large
        // blob copies it once per entry, amplifying a tiny file into gigabytes of resident memory. A real WE
        // package is contiguous (the blobs tile the region exactly once), so the copied total is about the file
        // size; cap it at a small multiple of the data with a fixed floor for small files.
        let copyBudget = max(64 << 20, data.count * 2)
        var copied = 0
        for entry in table {
            let start = blobBase + entry.offset
            let end = start + entry.size
            guard entry.offset >= 0, entry.size >= 0, end <= data.count else {
                throw ScenePackageError.entryOutOfBounds(path: entry.path)
            }
            copied += entry.size
            guard copied <= copyBudget else { throw ScenePackageError.truncated }
            let slice = data.subdata(in: base + start ..< base + end)
            entries.append(ScenePackageEntry(path: entry.path, data: slice))
        }
        return ScenePackage(version: version, entries: entries)
    }
}

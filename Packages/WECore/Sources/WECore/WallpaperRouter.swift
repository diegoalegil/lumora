// SPDX-License-Identifier: MIT
// Provenance: clean-room. The architectural spine: project.json.type -> which player.
import Foundation

/// Reads a manifest's `type` and resolves the wallpaper to a scope-checked, ready-to-play
/// descriptor. Pure and dependency-free: it decides *what* to play and *which file*, not *how*
/// (instantiation is the App's job via `WallpaperPlayerFactory`).
public struct WallpaperRouter: Sendable {
    public init() {}

    /// Resolve a wallpaper from its folder + manifest, rejecting unsupported types
    /// (`application`) and empty/missing main files.
    public func resolve(ref: WallpaperRef, manifest: ProjectManifest) throws -> ResolvedWallpaper {
        let type = try WallpaperType.parse(manifest.rawType)
        guard !manifest.file.isEmpty else {
            throw RoutingError.missingMainFile(type: type)
        }
        let mainFileURL = ref.folderURL.appendingPathComponent(manifest.file)
        // The manifest is untrusted Workshop content: a `file` like "../../../etc/passwd" (or an
        // absolute path) would resolve outside the wallpaper's own folder, and the players read it
        // verbatim. Require the resolved path to stay inside the folder so a manifest can't name an
        // arbitrary file on disk.
        guard Self.path(mainFileURL, isWithin: ref.folderURL) else {
            throw RoutingError.unsafeMainFile(file: manifest.file)
        }
        return ResolvedWallpaper(ref: ref, type: type, manifest: manifest, mainFileURL: mainFileURL)
    }

    /// True when `url` points to a location strictly inside `folder`. Two layers, both must hold:
    /// 1. Lexical: collapse `.`/`..` WITHOUT touching the filesystem (`.standardized`) so an absolute or
    ///    `../` escape is rejected even when the asset doesn't exist on disk yet.
    /// 2. Symlink-resolved: the bundle is untrusted Workshop content, so it could contain a symlinked
    ///    subfolder pointing back out; resolve symlinks on both sides and re-check. `resolvingSymlinksInPath`
    ///    resolves the existing prefix (the folder and any real subfolders) consistently for both URLs and
    ///    leaves a not-yet-existing leaf in place, so the comparison stays well-defined.
    /// The trailing-slash guard rejects a sibling whose name merely shares the prefix (`/library/wall` is
    /// not "inside" `/library/wallpaper`).
    static func path(_ url: URL, isWithin folder: URL) -> Bool {
        let base = folder.standardized.path
        guard url.standardized.path.hasPrefix(base + "/") else { return false }
        let resolvedBase = folder.resolvingSymlinksInPath().standardized.path
        return url.resolvingSymlinksInPath().standardized.path.hasPrefix(resolvedBase + "/")
    }

    /// Load `project.json` from a folder and resolve in one step.
    public func resolve(folderURL: URL) throws -> ResolvedWallpaper {
        let manifestURL = folderURL.appendingPathComponent("project.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try ProjectManifest.decode(from: data)
        let ref = WallpaperRef(folderURL: folderURL, manifest: manifest)
        return try resolve(ref: ref, manifest: manifest)
    }
}

public enum RoutingError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingMainFile(type: WallpaperType)
    case unsafeMainFile(file: String)

    public var description: String {
        switch self {
        case .missingMainFile(let type):
            return "Manifest of type '\(type.rawValue)' has no main `file`."
        case .unsafeMainFile(let file):
            return "Manifest main `file` \"\(file)\" resolves outside the wallpaper folder."
        }
    }
}

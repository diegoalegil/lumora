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
        return ResolvedWallpaper(ref: ref, type: type, manifest: manifest, mainFileURL: mainFileURL)
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

    public var description: String {
        switch self {
        case .missingMainFile(let type):
            return "Manifest of type '\(type.rawValue)' has no main `file`."
        }
    }
}

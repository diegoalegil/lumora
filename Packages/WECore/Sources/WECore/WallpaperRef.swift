// SPDX-License-Identifier: MIT
// Provenance: clean-room.
import Foundation

/// Identifies a wallpaper on disk (one Steam Workshop folder = one wallpaper).
public struct WallpaperRef: Sendable, Equatable, Identifiable, Hashable {
    /// Stable id: the workshop id when known, else the folder name.
    public let id: String
    /// The wallpaper's root folder (contains project.json).
    public let folderURL: URL

    public init(id: String, folderURL: URL) {
        self.id = id
        self.folderURL = folderURL
    }

    /// Convenience: derive a ref from a folder, preferring the workshop id from the manifest.
    public init(folderURL: URL, manifest: ProjectManifest?) {
        self.folderURL = folderURL
        self.id = manifest?.workshopID ?? folderURL.lastPathComponent
    }

    public var projectJSONURL: URL { folderURL.appendingPathComponent("project.json") }
}

/// A fully resolved, scope-checked wallpaper ready to hand to a player.
public struct ResolvedWallpaper: Sendable, Equatable {
    public let ref: WallpaperRef
    public let type: WallpaperType
    public let manifest: ProjectManifest
    /// Absolute URL of the main asset (manifest.file resolved against the folder).
    public let mainFileURL: URL

    public init(ref: WallpaperRef, type: WallpaperType, manifest: ProjectManifest, mainFileURL: URL) {
        self.ref = ref
        self.type = type
        self.manifest = manifest
        self.mainFileURL = mainFileURL
    }
}

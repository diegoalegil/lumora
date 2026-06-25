// SPDX-License-Identifier: MIT
// Provenance: clean-room. Persists each wallpaper's user property overrides as JSON behind a small protocol,
// mirroring `PlaylistRepository`. Only genuine customizations are stored (defaults aren't), so the file stays
// small; a missing/corrupt file reads as "no overrides", never a crash.
import Foundation
import Observation
import WECore

/// A map of wallpaper id → (property key → user value).
public typealias WallpaperOverrides = [String: [String: PropertyValue]]

/// Loads and stores per-wallpaper property overrides.
public protocol WallpaperPropertyRepository {
    func load() -> WallpaperOverrides
    func save(_ overrides: WallpaperOverrides) throws
}

/// In-memory repository for previews and tests.
public final class InMemoryWallpaperPropertyRepository: WallpaperPropertyRepository {
    private var stored: WallpaperOverrides
    public init(_ initial: WallpaperOverrides = [:]) { stored = initial }
    public func load() -> WallpaperOverrides { stored }
    public func save(_ overrides: WallpaperOverrides) throws { stored = overrides }
}

/// JSON-file-backed repository (versioned envelope, like the playlist store).
public final class JSONWallpaperPropertyRepository: WallpaperPropertyRepository {
    struct Envelope: Codable { var version: Int; var overrides: WallpaperOverrides }
    static let currentVersion = 1
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func standard(fileManager: FileManager = .default) -> JSONWallpaperPropertyRepository {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false)) ?? fileManager.temporaryDirectory
        return JSONWallpaperPropertyRepository(fileURL: base.appendingPathComponent("Lumora/wallpaper-properties.json"))
    }

    public func load() -> WallpaperOverrides {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data) { return env.overrides }
        if let bare = try? JSONDecoder().decode(WallpaperOverrides.self, from: data) { return bare }
        return [:]
    }

    public func save(_ overrides: WallpaperOverrides) throws {
        let env = Envelope(version: Self.currentVersion, overrides: overrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(env)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Owns every wallpaper's overrides and persists changes. The per-wallpaper `WallpaperPropertiesModel` reads
/// and writes through this; the host creates one and keeps it for the app's lifetime.
@Observable
public final class WallpaperPropertyStore {
    public private(set) var all: WallpaperOverrides
    @ObservationIgnored private let repository: WallpaperPropertyRepository

    public init(repository: WallpaperPropertyRepository) {
        self.repository = repository
        self.all = repository.load()
    }

    /// The stored overrides for one wallpaper (empty when it has none).
    public func overrides(for wallpaperID: String) -> [String: PropertyValue] { all[wallpaperID] ?? [:] }

    /// Replace one wallpaper's overrides and persist. An empty map removes the entry entirely so the store
    /// never accumulates blank records.
    public func setOverrides(_ overrides: [String: PropertyValue], for wallpaperID: String) {
        if overrides.isEmpty { all.removeValue(forKey: wallpaperID) }
        else { all[wallpaperID] = overrides }
        try? repository.save(all)
    }
}

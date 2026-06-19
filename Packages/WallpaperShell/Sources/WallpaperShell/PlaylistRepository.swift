// SPDX-License-Identifier: MIT
// Provenance: clean-room. Persists the user's playlist library to disk as JSON behind a small protocol, so
// the rest of the app depends on the abstraction (and tests use an in-memory or temp-file double). A
// versioned envelope lets the on-disk format migrate forward idempotently. Never crashes on a bad file.
import Foundation
import WECore

/// Loads and stores the user's `PlaylistLibrary`. A protocol so the app can be tested against a double and a
/// real file-backed implementation can be swapped in.
public protocol PlaylistRepository {
    /// The persisted library, or an empty one if nothing is stored yet or the store is unreadable/corrupt.
    func load() -> PlaylistLibrary
    /// Persist the library, replacing whatever was there.
    func save(_ library: PlaylistLibrary) throws
}

/// An in-memory `PlaylistRepository` for SwiftUI previews and tests — holds the library in RAM, persists
/// nothing.
public final class InMemoryPlaylistRepository: PlaylistRepository {
    private var stored: PlaylistLibrary
    public init(_ initial: PlaylistLibrary = .init()) { stored = initial }
    public func load() -> PlaylistLibrary { stored }
    public func save(_ library: PlaylistLibrary) throws { stored = library }
}

/// A JSON-file-backed `PlaylistRepository`. The file holds a versioned envelope so a future format change is a
/// migration step, not a breaking read; a missing or corrupt file reads as an empty library (never a crash).
public final class JSONPlaylistRepository: PlaylistRepository, Sendable {
    /// On-disk shape: a version tag plus the library, so the reader can migrate older files forward.
    struct Envelope: Codable { var version: Int; var library: PlaylistLibrary }

    /// Bump when the persisted shape changes; add a case to `migrate(_:)` for each older version.
    static let currentVersion = 1

    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// The default store: `~/Library/Application Support/Lumora/playlists.json` (falls back to a temp path if
    /// Application Support can't be resolved, so it degrades instead of crashing).
    public static func standard(fileManager: FileManager = .default) -> JSONPlaylistRepository {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false)) ?? fileManager.temporaryDirectory
        return JSONPlaylistRepository(fileURL: base.appendingPathComponent("Lumora/playlists.json"))
    }

    public func load() -> PlaylistLibrary {
        guard let data = try? Data(contentsOf: fileURL) else { return PlaylistLibrary() }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return Self.migrate(envelope).library
        }
        // Tolerate an older/hand-written file that is a bare library or a bare array of playlists.
        if let bare = try? JSONDecoder().decode(PlaylistLibrary.self, from: data) { return bare }
        if let array = try? JSONDecoder().decode([Playlist].self, from: data) { return PlaylistLibrary(array) }
        return PlaylistLibrary()   // corrupt → empty, never crash
    }

    public func save(_ library: PlaylistLibrary) throws {
        let envelope = Envelope(version: Self.currentVersion, library: library)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Idempotent forward migration. v1 is current; older envelopes are upgraded field-by-field here. Running
    /// it twice yields the same result, so re-saving an already-current file is a no-op upgrade.
    static func migrate(_ envelope: Envelope) -> Envelope {
        var envelope = envelope
        // No structural migrations yet — the scaffold is here so a v2 reader is one `case`, not a rewrite.
        envelope.version = currentVersion
        return envelope
    }
}

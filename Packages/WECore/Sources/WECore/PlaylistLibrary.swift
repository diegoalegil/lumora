// SPDX-License-Identifier: MIT
// Provenance: clean-room. The user's collection of playlists with pure create/update/delete/reorder — all
// value-semantic so the editing behaviour is unit-testable; persistence (the repository) lives in the shell.
import Foundation

/// An ordered collection of playlists with pure CRUD and reorder operations. Holds no disk or UI state, so
/// every edit is a deterministic function of the value — the settings UI binds to it and the repository
/// persists it.
public struct PlaylistLibrary: Codable, Sendable, Equatable {
    public private(set) var playlists: [Playlist]

    public init(_ playlists: [Playlist] = []) { self.playlists = playlists }

    public func playlist(id: UUID) -> Playlist? { playlists.first { $0.id == id } }
    public var count: Int { playlists.count }
    public var isEmpty: Bool { playlists.isEmpty }

    /// Append a new playlist, or replace the existing one with the same id (upsert). Returns true if it was a
    /// new insertion, false if it replaced an existing playlist.
    @discardableResult
    public mutating func upsert(_ playlist: Playlist) -> Bool {
        if let i = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[i] = playlist
            return false
        }
        playlists.append(playlist)
        return true
    }

    /// Remove the playlist with `id` (no-op if absent).
    public mutating func remove(id: UUID) { playlists.removeAll { $0.id == id } }

    /// Move a single playlist from one index to another, clamping out-of-range targets (drag-reorder).
    public mutating func move(from: Int, to: Int) {
        guard playlists.indices.contains(from) else { return }
        let target = min(max(0, to), playlists.count - 1)
        guard from != target else { return }
        let moved = playlists.remove(at: from)
        playlists.insert(moved, at: target)
    }

    /// SwiftUI `.onMove` adapter: remove the items at `source` and re-insert them before `destination`, with
    /// the destination adjusted for removals ahead of it — matching `Array.move(fromOffsets:toOffset:)` without
    /// importing SwiftUI into this pure core.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { playlists.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.sorted().map { playlists[$0] }
        for i in valid.sorted(by: >) { playlists.remove(at: i) }
        let removedBefore = valid.filter { $0 < destination }.count
        let insertAt = min(max(0, destination - removedBefore), playlists.count)
        playlists.insert(contentsOf: moving, at: insertAt)
    }
}

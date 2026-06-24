// SPDX-License-Identifier: MIT
// Provenance: clean-room. The observable root the settings UI binds to: it holds the playlist library and the
// current selection, delegates edits to WECore's pure `PlaylistLibrary`, and persists every change through the
// repository. The store logic is unit-tested with an in-memory repository; the views are the owner's to verify.
import Foundation
import Observation
import WECore

/// Owns the user's `PlaylistLibrary` and the selected playlist, loaded from and saved to a `PlaylistRepository`.
/// Every mutation persists immediately, so the on-disk store always matches what the UI shows.
@Observable
public final class PlaylistStore {
    public private(set) var library: PlaylistLibrary
    public var selectedPlaylistID: UUID? {
        didSet {
            guard selectedPlaylistID != oldValue else { return }
            onSelectionChange?(selectedPlaylistID)
        }
    }

    @ObservationIgnored private let repository: PlaylistRepository
    /// Fires whenever the selection actually changes (UI pick, add, remove) — the host persists it so the
    /// chosen playlist is restored on the next launch. Not called for the initial load.
    @ObservationIgnored public var onSelectionChange: ((UUID?) -> Void)?

    /// - Parameter initialSelection: a previously-persisted selected playlist id to restore; honoured only if
    ///   it still exists in the loaded library, otherwise the first playlist is selected.
    public init(repository: PlaylistRepository, initialSelection: UUID? = nil,
                onSelectionChange: ((UUID?) -> Void)? = nil) {
        self.repository = repository
        let loaded = repository.load()
        self.library = loaded
        self.selectedPlaylistID = Self.resolveSelection(initialSelection, in: loaded)
        self.onSelectionChange = onSelectionChange   // set after init so the initial load doesn't notify
    }

    /// Honour a requested selection when it still exists; otherwise fall back to the first playlist (or nil).
    public static func resolveSelection(_ requested: UUID?, in library: PlaylistLibrary) -> UUID? {
        if let requested, library.playlist(id: requested) != nil { return requested }
        return library.playlists.first?.id
    }

    /// The currently selected playlist, if any.
    public var selectedPlaylist: Playlist? { selectedPlaylistID.flatMap { library.playlist(id: $0) } }

    /// Create a new playlist, select it, and persist.
    @discardableResult
    public func addPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        library.upsert(playlist)
        selectedPlaylistID = playlist.id
        persist()
        return playlist
    }

    /// Replace an existing playlist (e.g. after editing) and persist.
    public func update(_ playlist: Playlist) {
        library.upsert(playlist)
        persist()
    }

    /// Append a wallpaper to a playlist (ignoring duplicates) and persist. This is how the Library grid adds a
    /// wallpaper to a playlist; returns true if it was added.
    @discardableResult
    public func addItem(_ reference: WallpaperReference, toPlaylist id: UUID) -> Bool {
        guard var playlist = library.playlist(id: id), !playlist.items.contains(reference) else { return false }
        playlist.items.append(reference)
        library.upsert(playlist)
        persist()
        return true
    }

    /// Remove a playlist; if it was selected, fall back to the first remaining one. Persists.
    public func remove(id: UUID) {
        library.remove(id: id)
        if selectedPlaylistID == id { selectedPlaylistID = library.playlists.first?.id }
        persist()
    }

    /// Reorder the playlists (SwiftUI `.onMove`) and persist.
    public func movePlaylists(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() { try? repository.save(library) }
}

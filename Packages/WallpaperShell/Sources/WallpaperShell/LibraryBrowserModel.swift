// SPDX-License-Identifier: MIT
// Provenance: clean-room. Observable state for the library browser window: the installed entries plus the
// live search/filter/sort/selection the user drives. All the actual filtering is the pure `LibraryFiltering`
// (unit-tested); this just holds the UI state and exposes the derived, ordered view.
import Foundation
import Observation
import WECore

/// Backs the library browser. The view binds to `searchText`, `typeFilter`, `sortOrder` and `selectedID`;
/// `visibleEntries` recomputes from them. Replacing `entries` (e.g. after a rescan) keeps the selection if it
/// still exists.
@Observable
public final class LibraryBrowserModel {
    public var searchText: String = ""
    public var typeFilter: LibraryTypeFilter = .all
    public var sortOrder: LibrarySortOrder = .title
    public var selectedID: String?
    /// The wallpaper currently driving the desktop (highlighted in the grid / detail). App-owned; set by the host.
    public var activeWallpaperID: String?
    /// Show only starred wallpapers.
    public var showFavoritesOnly: Bool = false
    /// The starred wallpaper ids (kept in sync with persisted preferences by the host).
    public var favorites: Set<String> = []

    /// Fires when the user stars/unstars a wallpaper, with the full updated set, so the host persists it.
    @ObservationIgnored public var onFavoritesChange: ((Set<String>) -> Void)?

    public private(set) var entries: [LibraryEntry]

    public init(entries: [LibraryEntry] = []) {
        self.entries = entries
        self.selectedID = LibraryFiltering.apply(to: entries, search: "", type: .all, sort: .title).first?.id
    }

    /// The entries to show, after search + type facet + favorites + sort.
    public var visibleEntries: [LibraryEntry] {
        LibraryFiltering.apply(to: entries, search: searchText, type: typeFilter, sort: sortOrder,
                               favoritesOnly: showFavoritesOnly, favorites: favorites)
    }

    public func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    /// Star or unstar a wallpaper, publish the new set for persistence, and keep the selection valid (un-starring
    /// the selected one while showing favorites-only would otherwise strand the detail panel).
    public func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        onFavoritesChange?(favorites)
        if showFavoritesOnly { clampSelectionToVisible() }
    }

    /// Per-kind counts of the whole (unfiltered) library, for the facet labels.
    public var typeCounts: [WallpaperType: Int] { LibraryFiltering.counts(in: entries) }

    /// The currently selected entry, if it's still visible under the active filters.
    public var selectedEntry: LibraryEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    /// Swap in a fresh library (after a rescan), keeping the current selection when it survives AND is still
    /// visible under the active filters, else moving to the first visible entry so the detail panel is never
    /// stranded on a wallpaper that's gone or filtered out.
    public func replace(entries: [LibraryEntry]) {
        self.entries = entries
        clampSelectionToVisible()
    }

    /// Keep the selection valid as filters change: if the selected entry filtered out, fall back to the first
    /// visible one (or nil when the filter matches nothing).
    public func clampSelectionToVisible() {
        let visible = visibleEntries
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }
}

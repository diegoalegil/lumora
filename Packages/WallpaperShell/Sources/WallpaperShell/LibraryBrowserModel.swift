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

    public private(set) var entries: [LibraryEntry]

    public init(entries: [LibraryEntry] = []) {
        self.entries = entries
        self.selectedID = LibraryFiltering.apply(to: entries, search: "", type: .all, sort: .title).first?.id
    }

    /// The entries to show, after search + type facet + sort.
    public var visibleEntries: [LibraryEntry] {
        LibraryFiltering.apply(to: entries, search: searchText, type: typeFilter, sort: sortOrder)
    }

    /// Per-kind counts of the whole (unfiltered) library, for the facet labels.
    public var typeCounts: [WallpaperType: Int] { LibraryFiltering.counts(in: entries) }

    /// The currently selected entry, if it's still visible under the active filters.
    public var selectedEntry: LibraryEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    /// Swap in a fresh library (after a rescan), keeping the current selection when it survives, else moving to
    /// the first visible entry so the detail panel is never stranded on a wallpaper that's gone.
    public func replace(entries: [LibraryEntry]) {
        self.entries = entries
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleEntries.first?.id
    }

    /// Keep the selection valid as filters change: if the selected entry filtered out, fall back to the first
    /// visible one (or nil when the filter matches nothing).
    public func clampSelectionToVisible() {
        let visible = visibleEntries
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }
}

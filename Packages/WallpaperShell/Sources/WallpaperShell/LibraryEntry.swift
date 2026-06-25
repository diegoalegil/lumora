// SPDX-License-Identifier: MIT
// Provenance: clean-room. A presentation-friendly snapshot of one installed wallpaper for the library
// browser, plus the pure search/filter/sort logic that drives the grid. The host builds `LibraryEntry`
// values from `ResolvedWallpaper`; the filtering here is value-in/value-out so it can be unit-tested
// without any UI.
import Foundation
import WECore

/// One installed wallpaper as the browser needs to display and organize it. Lightweight and value-typed:
/// the real preview image loads lazily in the view from `thumbnailURL`.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    /// Stable wallpaper id (workshop id, else folder name).
    public let id: String
    /// Human title (never empty — the host substitutes the id when the manifest has none).
    public let title: String
    public let type: WallpaperType
    public let tags: [String]
    /// The manifest description, if any (shown in the detail panel).
    public let description: String?
    /// A local file URL for the preview image, or nil to show a placeholder.
    public let thumbnailURL: URL?
    /// The wallpaper's root folder (for "Show in Finder" and on-demand size).
    public let folderURL: URL

    public init(id: String, title: String, type: WallpaperType, tags: [String] = [],
                description: String? = nil, thumbnailURL: URL? = nil, folderURL: URL) {
        self.id = id
        self.title = title
        self.type = type
        self.tags = tags
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.folderURL = folderURL
    }

    /// Does this entry match a lowercased, already-trimmed query? Title or any tag substring.
    func matches(query lowercased: String) -> Bool {
        if title.lowercased().contains(lowercased) { return true }
        return tags.contains { $0.lowercased().contains(lowercased) }
    }
}

/// The "type" facet of the library: everything, or one wallpaper kind.
public enum LibraryTypeFilter: String, CaseIterable, Sendable, Identifiable {
    case all, scene, video, web
    public var id: String { rawValue }

    /// The label shown in the segmented control.
    public var label: String {
        switch self {
        case .all:   return "All"
        case .scene: return "Scenes"
        case .video: return "Videos"
        case .web:   return "Web"
        }
    }

    /// Does an entry of this wallpaper kind pass the filter?
    public func matches(_ type: WallpaperType) -> Bool {
        switch self {
        case .all:   return true
        case .scene: return type == .scene
        case .video: return type == .video
        case .web:   return type == .web
        }
    }
}

/// How the grid is ordered.
public enum LibrarySortOrder: String, CaseIterable, Sendable, Identifiable {
    /// Alphabetical by title (the default — matches the menu-bar list).
    case title
    /// Grouped by kind (scene/video/web), alphabetical within each group.
    case type
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: return "Title"
        case .type:  return "Type"
        }
    }
}

/// Pure, value-in/value-out search + filter + sort over library entries. No UI, no I/O — unit-tested.
public enum LibraryFiltering {
    /// Apply the search text, type facet and sort order, returning the visible, ordered entries.
    public static func apply(to entries: [LibraryEntry], search: String,
                             type: LibraryTypeFilter, sort: LibrarySortOrder) -> [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = entries.filter { entry in
            type.matches(entry.type) && (query.isEmpty || entry.matches(query: query))
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .title:
                return ordered(lhs, rhs)
            case .type:
                if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
                return ordered(lhs, rhs)
            }
        }
    }

    /// Stable title order: case/diacritic-insensitive by title, breaking ties on id so the order is
    /// deterministic even when two wallpapers share a title.
    private static func ordered(_ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
        let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Count of entries per kind in the unfiltered set (drives the facet badges).
    public static func counts(in entries: [LibraryEntry]) -> [WallpaperType: Int] {
        var counts: [WallpaperType: Int] = [:]
        for entry in entries { counts[entry.type, default: 0] += 1 }
        return counts
    }
}

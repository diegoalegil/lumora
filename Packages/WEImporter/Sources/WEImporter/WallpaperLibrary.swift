// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Presentation helpers for a discovered library: a stable, de-duplicated,
// title-sorted listing and the display name to show for a wallpaper.
import Foundation
import WECore

public enum WallpaperLibrary {
    /// The title to show for a wallpaper: its manifest title, or the folder/workshop id when the
    /// title is missing or empty.
    public static func displayTitle(_ wallpaper: ResolvedWallpaper) -> String {
        let title = wallpaper.manifest.title ?? ""
        return title.isEmpty ? wallpaper.ref.id : title
    }

    /// De-duplicate by id (keeping the first occurrence — the same workshop item can appear in more
    /// than one Steam library) and sort by display title for a stable, user-friendly listing. Ties
    /// break on id so the order is deterministic.
    public static func presentable(_ wallpapers: [ResolvedWallpaper]) -> [ResolvedWallpaper] {
        var seen = Set<String>()
        let unique = wallpapers.filter { seen.insert($0.ref.id).inserted }
        return unique.sorted { lhs, rhs in
            switch displayTitle(lhs).localizedCaseInsensitiveCompare(displayTitle(rhs)) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return lhs.ref.id < rhs.ref.id
            }
        }
    }
}

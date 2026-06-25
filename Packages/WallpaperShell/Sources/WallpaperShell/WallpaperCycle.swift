// SPDX-License-Identifier: MIT
// Provenance: clean-room. Pure "next/previous wallpaper" cycling over an ordered id list, with wrap-around and
// sensible behaviour when the current id is unknown or the list is short. Used by the menu's Next/Previous
// commands in single-wallpaper mode; unit-tested without any AppKit.
import Foundation

public enum WallpaperCycle {
    /// The id after `current` in `ids`, wrapping at the end. If `current` is nil or not in `ids`, returns the
    /// first id. Returns nil only for an empty list.
    public static func next(after current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[(i + 1) % ids.count]
    }

    /// The id before `current` in `ids`, wrapping at the start. If `current` is nil or not in `ids`, returns the
    /// last id. Returns nil only for an empty list.
    public static func previous(before current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.last }
        return ids[(i - 1 + ids.count) % ids.count]
    }
}

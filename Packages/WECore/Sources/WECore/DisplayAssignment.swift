// SPDX-License-Identifier: MIT
// Provenance: clean-room. Which wallpaper shows on which monitor, resolved against the displays currently
// connected — pure logic keyed on stable display UUIDs (CGDisplayCreateUUIDFromDisplayID), so the multi-
// monitor behaviour is unit-testable without NSScreen. The resolution diff lets the host rebuild only the
// displays that actually changed instead of tearing everything down on every screen-configuration change.
import Foundation

/// The user's per-monitor wallpaper choice: an override per display plus a fallback for displays without one.
/// Stable display UUIDs are used so an assignment survives reboots, re-arrangement, and reconnection.
public struct DisplayAssignment: Codable, Sendable, Equatable {
    /// Display UUID → the wallpaper to show there. A display absent here uses `fallback`.
    public private(set) var overrides: [String: WallpaperReference]
    /// Shown on any connected display that has no override (nil = that display shows nothing).
    public var fallback: WallpaperReference?

    public init(overrides: [String: WallpaperReference] = [:], fallback: WallpaperReference? = nil) {
        self.overrides = overrides
        self.fallback = fallback
    }

    /// The wallpaper for one display: its override if set, else the fallback.
    public func reference(for displayUUID: String) -> WallpaperReference? {
        overrides[displayUUID] ?? fallback
    }

    /// Set (or clear, with nil) a single display's override.
    public mutating func setOverride(_ reference: WallpaperReference?, for displayUUID: String) {
        if let reference { overrides[displayUUID] = reference } else { overrides[displayUUID] = nil }
    }

    /// Resolve every CURRENTLY connected display to its wallpaper. Overrides for displays that aren't connected
    /// are ignored (but retained in storage, so reconnecting a monitor restores its choice). Displays with no
    /// wallpaper (no override and no fallback) are omitted from the result.
    public func resolve(connectedDisplays: [String]) -> [String: WallpaperReference] {
        var result: [String: WallpaperReference] = [:]
        for uuid in connectedDisplays {
            if let reference = reference(for: uuid) { result[uuid] = reference }
        }
        return result
    }
}

/// What changed between two resolutions, so the host updates only the affected displays. `added` need a new
/// surface, `removed` are torn down, `changed` re-apply their (new) wallpaper, `unchanged` are left alone.
public struct DisplayResolutionDiff: Sendable, Equatable {
    public let added: [String]
    public let removed: [String]
    public let changed: [String]
    public let unchanged: [String]

    /// Diff `old` → `new` (both display-UUID → wallpaper). Lists are sorted for deterministic results.
    public init(from old: [String: WallpaperReference], to new: [String: WallpaperReference]) {
        var added: [String] = [], removed: [String] = [], changed: [String] = [], unchanged: [String] = []
        for (uuid, reference) in new {
            if let existing = old[uuid] {
                if existing == reference { unchanged.append(uuid) } else { changed.append(uuid) }
            } else {
                added.append(uuid)
            }
        }
        for uuid in old.keys where new[uuid] == nil { removed.append(uuid) }
        self.added = added.sorted()
        self.removed = removed.sorted()
        self.changed = changed.sorted()
        self.unchanged = unchanged.sorted()
    }

    /// True when nothing changed — the host can skip all work.
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

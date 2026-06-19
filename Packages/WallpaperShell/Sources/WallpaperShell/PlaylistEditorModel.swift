// SPDX-License-Identifier: MIT
// Provenance: clean-room. The editable view-model for one playlist that the SwiftUI editor binds to. Its
// UI-facing conversions and clamps (minutes↔seconds, duration bounds, no-duplicate add, reorder/remove) are
// pure logic, unit-tested here so the view itself can stay a thin, owner-verified shell.
import Foundation
import Observation
import WECore

/// An observable wrapper around a `Playlist` being edited. Exposes the fields the settings editor binds to,
/// with the conversions and clamping a slider/stepper needs, so the view doesn't carry logic.
@Observable
public final class PlaylistEditorModel {
    public var playlist: Playlist

    public init(_ playlist: Playlist) { self.playlist = playlist }

    /// A sensible default interval (5 min) when auto-rotation is first switched on.
    public static let defaultIntervalSeconds: TimeInterval = 300
    /// Slider bounds, in the units the UI shows.
    public static let maxIntervalMinutes: Double = 1440          // 24 hours
    public static let minIntervalMinutes: Double = 0.5           // 30 seconds
    public static let maxTransitionSeconds: Double = 10

    public var name: String {
        get { playlist.name }
        set { playlist.name = newValue }
    }
    public var mode: PlaybackMode {
        get { playlist.mode }
        set { playlist.mode = newValue }
    }
    public var transitionKind: TransitionKind {
        get { playlist.transition.kind }
        set { playlist.transition.kind = newValue }
    }
    public var monitorTarget: DisplayTarget {
        get { playlist.displayTarget }
        set { playlist.displayTarget = newValue }
    }

    /// Whether the playlist auto-rotates. Turning it off clears the interval; turning it on restores the last
    /// interval, or the default if none was set.
    public var autoRotates: Bool {
        get { playlist.effectiveRotationInterval != nil }
        set { playlist.rotationInterval = newValue ? (playlist.effectiveRotationInterval ?? Self.defaultIntervalSeconds) : nil }
    }

    /// Rotation interval in MINUTES for the UI, clamped to a sane range and stored back as seconds. Reads 0
    /// when auto-rotation is off.
    public var rotationIntervalMinutes: Double {
        get { (playlist.effectiveRotationInterval ?? 0) / 60 }
        set {
            guard newValue > 0 else { playlist.rotationInterval = nil; return }
            playlist.rotationInterval = min(Self.maxIntervalMinutes, max(Self.minIntervalMinutes, newValue)) * 60
        }
    }

    /// Cross-fade length in seconds, clamped to `[0, maxTransitionSeconds]`.
    public var transitionDurationSeconds: Double {
        get { playlist.transition.duration }
        set { playlist.transition.duration = min(Self.maxTransitionSeconds, max(0, newValue)) }
    }

    public var items: [WallpaperReference] { playlist.items }

    /// Add a wallpaper, ignoring duplicates (a playlist holds each wallpaper at most once).
    public func addItem(_ reference: WallpaperReference) {
        guard !playlist.items.contains(reference) else { return }
        playlist.items.append(reference)
    }

    /// Remove the items at the given offsets (SwiftUI `.onDelete`).
    public func removeItems(atOffsets offsets: IndexSet) {
        for i in offsets.sorted(by: >) where playlist.items.indices.contains(i) {
            playlist.items.remove(at: i)
        }
    }

    /// Reorder the items (SwiftUI `.onMove`): remove the items at `source` and re-insert them before
    /// `destination`, adjusting for removals ahead of it.
    public func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { playlist.items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.sorted().map { playlist.items[$0] }
        for i in valid.sorted(by: >) { playlist.items.remove(at: i) }
        let removedBefore = valid.filter { $0 < destination }.count
        let insertAt = min(max(0, destination - removedBefore), playlist.items.count)
        playlist.items.insert(contentsOf: moving, at: insertAt)
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. The playlist value model and its play-order resolution — pure, dependency-free
// logic so the rotation/scheduling behaviour is fully unit-testable without any AppKit or disk.
import Foundation

/// A stable reference to a wallpaper in the user's library — its id (the Steam Workshop id, else the folder
/// name). A playlist stores references, never copies of the wallpaper bundle; the library resolves an id to a
/// `ResolvedWallpaper` at playback time.
public struct WallpaperReference: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// How a playlist orders its items for playback.
public enum PlaybackMode: String, Codable, Sendable, CaseIterable {
    /// Play items in their stored order, looping.
    case inOrder
    /// Play a deterministic shuffle of the items, looping.
    case shuffle
    /// Pick the next item at random, never the same one twice in a row.
    case randomNoImmediateRepeat
}

/// How a playlist visually changes from one wallpaper to the next.
public enum TransitionKind: String, Codable, Sendable, CaseIterable {
    /// Swap instantly (hard cut).
    case none
    /// Cross-fade: the outgoing and incoming wallpapers overlap while opacity ramps over `duration`.
    case crossfade
}

/// The transition applied when a playlist advances.
public struct TransitionSettings: Codable, Sendable, Equatable {
    public var kind: TransitionKind
    /// Cross-fade length in seconds (ignored for `.none`). Always read as a non-negative value.
    public var duration: TimeInterval

    public init(kind: TransitionKind = .crossfade, duration: TimeInterval = 1.0) {
        self.kind = kind
        self.duration = duration
    }

    /// The duration to actually use — finite and non-negative — so a corrupt/hand-edited value can't drive a
    /// negative or NaN ramp.
    public var effectiveDuration: TimeInterval { duration.isFinite ? max(0, duration) : 0 }
}

/// Which display(s) a playlist drives.
public enum DisplayTarget: Codable, Sendable, Hashable {
    /// Every display shows this playlist.
    case all
    /// Only the display with this stable UUID (`CGDisplayCreateUUIDFromDisplayID`).
    case display(uuid: String)
}

/// An ordered set of wallpapers with how and where to play them. A pure value type — persistence and
/// resolution live elsewhere; this only models the data and its play order.
public struct Playlist: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var items: [WallpaperReference]
    public var mode: PlaybackMode
    /// Seconds between automatic advances; nil (or non-positive) means no auto-rotation (manual only).
    public var rotationInterval: TimeInterval?
    public var transition: TransitionSettings
    public var displayTarget: DisplayTarget

    public init(id: UUID = UUID(), name: String, items: [WallpaperReference] = [],
                mode: PlaybackMode = .inOrder, rotationInterval: TimeInterval? = nil,
                transition: TransitionSettings = .init(), displayTarget: DisplayTarget = .all) {
        self.id = id
        self.name = name
        self.items = items
        self.mode = mode
        self.rotationInterval = rotationInterval
        self.transition = transition
        self.displayTarget = displayTarget
    }

    /// The rotation interval to actually use, or nil if auto-rotation is off — guards a corrupt/hand-edited
    /// value (non-finite or ≤ 0) into "no auto-rotation".
    public var effectiveRotationInterval: TimeInterval? {
        guard let interval = rotationInterval, interval.isFinite, interval > 0 else { return nil }
        return interval
    }

    /// The play order for this playlist, deterministic given `seed`: stored order for `.inOrder`, a seeded
    /// shuffle otherwise. For `.randomNoImmediateRepeat` the scheduler then draws random indices INTO this
    /// array rather than walking it, so the shuffle only sets the (random) STARTING item — that's intentional,
    /// not wasted. Pure — same (items, mode, seed) always yields the same order.
    public func resolvedOrder(seed: UInt64) -> [WallpaperReference] {
        switch mode {
        case .inOrder:
            return items
        case .shuffle, .randomNoImmediateRepeat:
            var rng = SplitMix64(seed: seed)
            return items.shuffled(using: &rng)
        }
    }
}

/// A small, deterministic, seedable PRNG (SplitMix64) so shuffles and random picks are reproducible in tests
/// and stable across launches given the same seed. Not for cryptography.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

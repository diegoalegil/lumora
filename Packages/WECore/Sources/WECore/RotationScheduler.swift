// SPDX-License-Identifier: MIT
// Provenance: clean-room. The timed-rotation state machine for a playlist — a PURE value type whose only
// notion of "now" is the time the caller passes in, so the whole advance/pause/skip behaviour is
// deterministic and unit-testable without a real clock, timer, or AppKit.
import Foundation

/// Drives a playlist's current item over time. The host calls `tick(now:)` on a timer; the scheduler advances
/// only when at least the rotation interval has elapsed since the last change, and reports the new item (or
/// nil if nothing changed). Manual `next`/`previous` and `pause`/`resume` are also time-injected so they
/// compose with the same clock. All state transitions are pure functions of (state, now).
public struct RotationScheduler: Sendable {
    /// The fixed play order (stored order for `.inOrder`, a seeded shuffle otherwise). For
    /// `.randomNoImmediateRepeat` this is just the item set; the next item is drawn at random from it.
    public private(set) var order: [WallpaperReference]
    /// Index into `order` of the item currently shown.
    public private(set) var index: Int
    /// Seconds between automatic advances, or nil for manual-only.
    public let interval: TimeInterval?
    public private(set) var isPaused: Bool

    private let mode: PlaybackMode
    private var lastAdvance: TimeInterval
    private var pausedElapsed: TimeInterval
    private var rng: SplitMix64

    /// Build a scheduler for `playlist`, seeded for a reproducible shuffle, starting at `now`.
    public init(playlist: Playlist, seed: UInt64, now: TimeInterval) {
        self.order = playlist.resolvedOrder(seed: seed)
        self.index = 0
        self.interval = playlist.effectiveRotationInterval
        self.mode = playlist.mode
        self.isPaused = false
        self.lastAdvance = now
        self.pausedElapsed = 0
        self.rng = SplitMix64(seed: seed &+ 0x1234_5678)
    }

    /// The item currently shown, or nil if the playlist is empty.
    public var current: WallpaperReference? { order.indices.contains(index) ? order[index] : nil }

    /// Advance if (and only if) the rotation interval has elapsed since the last change and we're not paused.
    /// Returns the new current item when it changed, else nil. Advances at most one step per call, so a long
    /// gap (sleep/wake) doesn't race through the playlist.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> WallpaperReference? {
        guard !isPaused, let interval, order.count > 1, now - lastAdvance >= interval else { return nil }
        index = stepped(forward: true)
        lastAdvance = now
        return current
    }

    /// Manually move to the next item, restarting the interval from `now`. A manual skip while paused keeps
    /// rotation frozen (it does not implicitly resume) but clears the carried-over elapsed time, so a later
    /// `resume` gives the newly-selected wallpaper a full interval instead of a stale pre-skip remainder.
    @discardableResult
    public mutating func next(now: TimeInterval) -> WallpaperReference? {
        guard order.count > 1 else { return current }
        index = stepped(forward: true)
        lastAdvance = now
        pausedElapsed = 0
        return current
    }

    /// Manually move to the previous item, restarting the interval from `now` (same paused-skip contract as
    /// `next`). In `.randomNoImmediateRepeat` there is no history, so this draws a fresh non-repeating random
    /// item rather than the one shown before the current item (matching Wallpaper Engine's behaviour).
    @discardableResult
    public mutating func previous(now: TimeInterval) -> WallpaperReference? {
        guard order.count > 1 else { return current }
        index = stepped(forward: false)
        lastAdvance = now
        pausedElapsed = 0
        return current
    }

    /// Freeze rotation, remembering how far into the interval we were so `resume` continues from there.
    public mutating func pause(now: TimeInterval) {
        guard !isPaused else { return }
        pausedElapsed = max(0, now - lastAdvance)
        isPaused = true
    }

    /// Resume rotation, carrying over the elapsed time captured at `pause` so a wallpaper isn't cut short.
    public mutating func resume(now: TimeInterval) {
        guard isPaused else { return }
        lastAdvance = now - pausedElapsed
        pausedElapsed = 0
        isPaused = false
    }

    /// The index one step away. `.inOrder`/`.shuffle` walk the fixed order (wrapping); `.randomNoImmediateRepeat`
    /// draws a different index at random.
    private mutating func stepped(forward: Bool) -> Int {
        guard order.count > 1 else { return index }
        switch mode {
        case .inOrder, .shuffle:
            return forward ? (index + 1) % order.count : (index - 1 + order.count) % order.count
        case .randomNoImmediateRepeat:
            var candidate = index
            while candidate == index { candidate = Int(rng.next() % UInt64(order.count)) }
            return candidate
        }
    }
}

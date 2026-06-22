// SPDX-License-Identifier: MIT
// Provenance: clean-room. Plays a playlist on one display end-to-end: WECore's RotationScheduler decides WHEN
// to change and to WHAT, and a DisplaySwitcher performs the cross-fade. The host ticks it with the current
// time; everything in between is pure orchestration, so timed-rotation-with-transition is testable with mocks.
import Foundation
import WECore

/// Binds a playlist's rotation schedule to a display's switcher. On each `tick` it advances the rotation clock
/// and, when the scheduler moves to a new wallpaper, cross-fades the display to it using the playlist's
/// transition. Manual `next`/`previous` and `pause`/`resume` flow through to the schedule.
@MainActor
public final class PlaylistPlaybackController {
    private var scheduler: RotationScheduler
    private let switcher: DisplaySwitcher
    private let transition: TransitionSettings

    /// Start playing `playlist` on `switcher`, showing its first item immediately (an instant cut — there's
    /// nothing to fade from). `seed` makes a shuffled order reproducible; `now` seeds the rotation clock.
    public init(playlist: Playlist, seed: UInt64, now: TimeInterval, switcher: DisplaySwitcher) {
        self.scheduler = RotationScheduler(playlist: playlist, seed: seed, now: now)
        self.switcher = switcher
        self.transition = playlist.transition
        if let first = scheduler.current {
            switcher.apply(first, transition: TransitionSettings(kind: .none, duration: 0), now: now)
        }
    }

    /// The wallpaper the schedule currently points at.
    public var currentReference: WallpaperReference? { scheduler.current }
    public var isTransitioning: Bool { switcher.isTransitioning }

    /// Drive the rotation clock and any in-flight fade. If the schedule advances, cross-fade to the new
    /// wallpaper with the playlist's transition; then advance the fade itself.
    public func tick(now: TimeInterval) {
        if let next = scheduler.tick(now: now) {
            switcher.apply(next, transition: transition, now: now)
        }
        switcher.tick(now: now)
    }

    /// Manually skip to the next wallpaper now (restarting the rotation interval).
    public func next(now: TimeInterval) {
        if let reference = scheduler.next(now: now) { switcher.apply(reference, transition: transition, now: now) }
    }

    /// Manually go to the previous wallpaper now.
    public func previous(now: TimeInterval) {
        if let reference = scheduler.previous(now: now) { switcher.apply(reference, transition: transition, now: now) }
    }

    public func pause(now: TimeInterval) { scheduler.pause(now: now) }
    public func resume(now: TimeInterval) { scheduler.resume(now: now) }

    /// Forward a playback-policy directive (rendering on/off + frame rate) to the display's live surface.
    public func apply(_ directive: PlaybackDirective) { switcher.apply(directive) }

    /// Release the display's surfaces.
    public func teardown() { switcher.teardown() }
}

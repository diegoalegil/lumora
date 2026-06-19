// SPDX-License-Identifier: MIT
// Provenance: clean-room. Drives the whole desktop from a PlaybackPlan: one PlaylistPlaybackController per
// display, each over its own DisplaySwitcher. Applying a new plan starts/stops/restarts only the displays that
// changed (so an unaffected display keeps playing without a flash). Pure orchestration over an injected
// per-display switcher factory + clock, so it's unit-tested with recording switchers; the real switchers wrap
// windows + engine renderers.
import Foundation
import WECore

/// Coordinates playlist playback across every connected display. Feed it a `PlaybackPlan` (which playlist runs
/// where) and `tick` it on a timer; it owns the per-display controllers and reconciles them on each plan.
@MainActor
public final class WallpaperPlaybackCoordinator {
    private var controllers: [String: PlaylistPlaybackController] = [:]
    private var plan = PlaybackPlan()

    private let makeSwitcher: (String) -> DisplaySwitcher
    private let nextSeed: () -> UInt64

    /// - Parameters:
    ///   - makeSwitcher: builds the `DisplaySwitcher` for a display UUID (the real app binds it to that
    ///     display's window + renderer factory; tests return a recording switcher).
    ///   - seed: a per-controller shuffle seed (default 0 → deterministic; the app can vary it per start).
    public init(makeSwitcher: @escaping (String) -> DisplaySwitcher, seed: @escaping () -> UInt64 = { 0 }) {
        self.makeSwitcher = makeSwitcher
        self.nextSeed = seed
    }

    /// Displays that currently have a playlist running.
    public var activeDisplays: [String] { controllers.keys.sorted() }
    /// The wallpaper currently shown on a display.
    public func currentReference(forDisplay uuid: String) -> WallpaperReference? { controllers[uuid]?.currentReference }

    /// Reconcile to `newPlan`: stop displays that lost their playlist, (re)start displays that gained one or
    /// switched to a different playlist, and leave unchanged displays running.
    public func apply(_ newPlan: PlaybackPlan, now: TimeInterval) {
        let diff = PlaybackPlanDiff(from: plan, to: newPlan)
        for uuid in diff.stopped {
            controllers[uuid]?.teardown()
            controllers[uuid] = nil
        }
        for uuid in diff.started + diff.restarted {
            controllers[uuid]?.teardown()
            if let playlist = newPlan.playlist(forDisplay: uuid) {
                controllers[uuid] = PlaylistPlaybackController(playlist: playlist, seed: nextSeed(), now: now,
                                                              switcher: makeSwitcher(uuid))
            } else {
                controllers[uuid] = nil
            }
        }
        plan = newPlan
    }

    /// Advance every display's rotation clock and any in-flight cross-fade.
    public func tick(now: TimeInterval) {
        for controller in controllers.values { controller.tick(now: now) }
    }

    /// Manually skip a single display forward/back.
    public func next(display uuid: String, now: TimeInterval) { controllers[uuid]?.next(now: now) }
    public func previous(display uuid: String, now: TimeInterval) { controllers[uuid]?.previous(now: now) }

    /// Pause / resume rotation on all displays (the renderers themselves are paused via the playback policy).
    public func pause(now: TimeInterval) { for controller in controllers.values { controller.pause(now: now) } }
    public func resume(now: TimeInterval) { for controller in controllers.values { controller.resume(now: now) } }

    /// Stop and release every display.
    public func teardown() {
        for controller in controllers.values { controller.teardown() }
        controllers.removeAll()
        plan = PlaybackPlan()
    }
}

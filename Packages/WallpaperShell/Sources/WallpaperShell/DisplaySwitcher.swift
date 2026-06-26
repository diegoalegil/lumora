// SPDX-License-Identifier: MIT
// Provenance: clean-room. The switch spine for one display: it changes the live wallpaper, cross-fading via
// WECore's TransitionController by keeping the outgoing surface alive and ramping opacity until the fade
// completes. Orchestration only — the actual window/renderer sits behind the `WallpaperSurface` protocol, so
// this whole flow is unit-testable with a recording double and an injected clock.
import Foundation
import WECore

/// One wallpaper mounted on a display's surface. The real implementation owns an `NSWindow` + renderer; tests
/// use a recording double. Opacity is what the cross-fade drives. Main-actor isolated — the desktop is only
/// ever updated on the main thread.
@MainActor
public protocol WallpaperSurface: AnyObject {
    var reference: WallpaperReference { get }
    /// Set the surface's opacity (0 = transparent, 1 = opaque) — the cross-fade ramps this.
    func setOpacity(_ opacity: Double)
    /// Apply a playback directive (enable/disable rendering + target frame rate) to the live renderer.
    func apply(_ directive: PlaybackDirective)
    /// Tear down the surface (close its window, release its renderer). Called when it's no longer shown.
    func teardown()
}

/// Switches the wallpaper on a single display. A cross-fade overlaps the outgoing and incoming surfaces and
/// ramps their opacity to `duration`; anything else is an instant cut. The host calls `apply` to switch and
/// `tick` on a timer to advance a fade. Pure orchestration over an injected surface factory + clock.
@MainActor
public final class DisplaySwitcher {
    private let makeSurface: (WallpaperReference) -> WallpaperSurface
    private var current: WallpaperSurface?
    private var incoming: WallpaperSurface?
    private var transition = TransitionController()
    /// The most recent playback directive, re-applied to every newly-mounted surface. A surface starts its
    /// renderer at full rate, but a switch or playlist rotation can mount one while the display is occluded, on
    /// battery, or thermally throttled — without this, the new surface would burn full FPS until the next
    /// unrelated power/occlusion event re-pushed the directive.
    private var lastDirective: PlaybackDirective = .active

    /// - Parameter makeSurface: builds (and mounts) a surface for a wallpaper reference. The real app returns a
    ///   window-backed surface; tests return a recording double.
    public init(makeSurface: @escaping (WallpaperReference) -> WallpaperSurface) {
        self.makeSurface = makeSurface
    }

    /// The wallpaper currently shown (the incoming one during a fade), or nil if nothing is mounted yet.
    public var currentReference: WallpaperReference? { (incoming ?? current)?.reference }
    /// Whether a cross-fade is in progress (both surfaces alive).
    public var isTransitioning: Bool { transition.phase == .crossfading }

    /// Switch to `reference`. With an existing wallpaper and a cross-fade transition, both overlap and ramp;
    /// otherwise it's an instant cut. Switching to the wallpaper already shown (and not mid-fade) is a no-op.
    public func apply(_ reference: WallpaperReference, transition settings: TransitionSettings, now: TimeInterval) {
        // Re-requesting the wallpaper already shown OR currently fading IN is a true no-op — check the incoming
        // target too, not just `current`. Without this, re-applying B mid-fade collapses the fade and allocates
        // a fresh B surface (a new GPU renderer) only to cross-fade B onto itself. A switch back to the
        // OUTGOING wallpaper still proceeds (currentReference is the incoming one, which differs).
        if currentReference == reference { return }
        if isTransitioning { finishTransition() }   // collapse an in-flight fade before starting the next
        let surface = makeSurface(reference)
        // Start in the current policy, not always full-rate. A surface's renderer naturally resumes at full
        // rate, so only push a non-default directive (paused/throttled) — otherwise the mount is already correct.
        if lastDirective != .active { surface.apply(lastDirective) }
        if settings.kind == .crossfade, settings.effectiveDuration > 0, current != nil {
            surface.setOpacity(0)
            incoming = surface
            transition.begin(.crossfade, duration: settings.effectiveDuration, now: now)
        } else {
            current?.teardown()
            current = surface
            surface.setOpacity(1)
        }
    }

    /// Advance an in-flight cross-fade: update both opacities, and when it finishes, tear down the outgoing
    /// surface and promote the incoming one. A no-op when idle.
    public func tick(now: TimeInterval) {
        guard isTransitioning else { return }
        current?.setOpacity(transition.outgoingOpacity(at: now))
        incoming?.setOpacity(transition.incomingOpacity(at: now))
        if transition.tick(now: now) { finishTransition() }
    }

    /// Forward a playback directive to the live surface(s). During a cross-fade both the outgoing and
    /// incoming surfaces get it, so neither stalls mid-transition.
    public func apply(_ directive: PlaybackDirective) {
        lastDirective = directive
        current?.apply(directive)
        incoming?.apply(directive)
    }

    /// Release every surface this switcher owns.
    public func teardown() {
        current?.teardown()
        incoming?.teardown()
        current = nil
        incoming = nil
        transition = TransitionController()
    }

    private func finishTransition() {
        current?.teardown()
        if let incoming {
            incoming.setOpacity(1)
            current = incoming
        }
        incoming = nil
        transition = TransitionController()
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. The "don't render what isn't visible" rule as a PURE, testable
// state machine. The shell feeds it signals; it emits a PlaybackDirective per window.
import Foundation
import WECore

/// All the signals that determine whether/how fast a wallpaper should render.
public struct PlaybackInputs: Sendable, Equatable {
    /// The desktop window reports itself occluded — the primary, authoritative "not visible"
    /// signal (a fullscreen/maximized app covering the desktop turns this on).
    public var isOccluded: Bool
    /// Optional secondary "covered" signal. The engine honors it, but NO Phase 0 monitor populates
    /// it yet (it defaults to `false`) — occlusion is sufficient for the Phase 0 solid-color
    /// renderer. A dedicated fullscreen heuristic can be wired here later if occlusion proves
    /// insufficient once GPU-heavy players land.
    public var desktopCoveredByFullscreenApp: Bool
    /// Running on battery power (no AC).
    public var onBattery: Bool
    /// macOS Low Power Mode is enabled.
    public var lowPowerMode: Bool
    /// The user explicitly paused the wallpaper.
    public var userPaused: Bool
    /// The display is asleep / screensaver active.
    public var displayAsleep: Bool
    /// The screen is locked or the screensaver is running — visible to no one, so don't render at all.
    public var screenLocked: Bool
    /// The Mac is under serious/critical thermal pressure; throttle to shed sustained GPU/CPU load
    /// (render slower, but keep animating — pausing would freeze the wallpaper whenever the Mac runs warm).
    public var thermallyThrottled: Bool

    public init(isOccluded: Bool = false,
                desktopCoveredByFullscreenApp: Bool = false,
                onBattery: Bool = false,
                lowPowerMode: Bool = false,
                userPaused: Bool = false,
                displayAsleep: Bool = false,
                screenLocked: Bool = false,
                thermallyThrottled: Bool = false) {
        self.isOccluded = isOccluded
        self.desktopCoveredByFullscreenApp = desktopCoveredByFullscreenApp
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.userPaused = userPaused
        self.displayAsleep = displayAsleep
        self.screenLocked = screenLocked
        self.thermallyThrottled = thermallyThrottled
    }
}

/// Tunable frame-rate targets.
public struct PlaybackPolicy: Sendable, Equatable {
    public var activeFPS: Int
    public var batteryFPS: Int

    public init(activeFPS: Int = 60, batteryFPS: Int = 30) {
        self.activeFPS = activeFPS
        self.batteryFPS = batteryFPS
    }

    /// Sanitize user-entered rates into a usable policy: the active rate is clamped to 15…120 fps, and the
    /// throttled rate to 10 fps … the active rate (a throttle that exceeds the normal rate is meaningless).
    public static func clamped(activeFPS: Int, batteryFPS: Int) -> PlaybackPolicy {
        let active = min(120, max(15, activeFPS))
        let battery = min(active, max(10, batteryFPS))
        return PlaybackPolicy(activeFPS: active, batteryFPS: battery)
    }
}

/// Maps the current signals onto a `PlaybackDirective`. Pure and deterministic.
public struct PlaybackPolicyEngine: Sendable {
    public var policy: PlaybackPolicy

    public init(policy: PlaybackPolicy = .init()) {
        self.policy = policy
    }

    public func directive(for inputs: PlaybackInputs) -> PlaybackDirective {
        // Any "not visible" or explicit-pause signal stops rendering entirely.
        if inputs.userPaused
            || inputs.displayAsleep
            || inputs.screenLocked
            || inputs.isOccluded
            || inputs.desktopCoveredByFullscreenApp {
            return .paused
        }
        // Otherwise render, throttling on battery / low-power / thermal pressure.
        let fps = (inputs.onBattery || inputs.lowPowerMode || inputs.thermallyThrottled) ? policy.batteryFPS : policy.activeFPS
        return PlaybackDirective(renderingEnabled: true, targetFPS: fps)
    }
}

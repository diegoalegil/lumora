// SPDX-License-Identifier: MIT
// Provenance: clean-room. Aggregates the three system monitors into the PlaybackSignalSource the
// coordinator consumes. Occlusion is per-window; power/sleep are global.
import AppKit

@MainActor
public final class SystemSignalSource: PlaybackSignalSource {
    public var onChange: (() -> Void)?

    /// Set by the UI when the user explicitly pauses all wallpapers.
    public var userPaused = false

    private let occlusion = OcclusionMonitor()
    private let power = PowerMonitor()
    private let workspace = WorkspaceMonitor()
    private let windowForDisplay: (CGDirectDisplayID) -> NSWindow?

    /// - Parameter windowForDisplay: resolves a display id to its wallpaper window (from ScreenManager).
    public init(windowForDisplay: @escaping (CGDirectDisplayID) -> NSWindow?) {
        self.windowForDisplay = windowForDisplay
    }

    public func start() {
        let forward: () -> Void = { [weak self] in self?.onChange?() }
        occlusion.onChange = forward
        power.onChange = forward
        workspace.onChange = forward
        occlusion.start()
        power.start()
        workspace.start()
    }

    public func stop() {
        occlusion.stop()
        power.stop()
        workspace.stop()
    }

    public func globalInputs() -> PlaybackInputs {
        PlaybackInputs(
            onBattery: power.isOnBattery,
            lowPowerMode: power.isLowPowerMode,
            userPaused: userPaused,
            displayAsleep: workspace.isDisplayAsleep,
            screenLocked: workspace.isScreenLocked,
            thermallyThrottled: power.isThermallyThrottled
        )
    }

    public func isOccluded(displayID: CGDirectDisplayID) -> Bool {
        guard let window = windowForDisplay(displayID) else { return false }
        return !occlusion.isVisible(window)
    }
}

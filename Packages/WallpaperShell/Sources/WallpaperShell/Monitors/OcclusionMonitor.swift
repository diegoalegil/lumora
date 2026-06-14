// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSWindow.occlusionState, didChangeOcclusionState).
// Occlusion is the most reliable "not visible" signal — a fullscreen/maximized app covering the
// desktop turns the wallpaper window's `.visible` off, which is exactly when we should pause.
import AppKit

@MainActor
public final class OcclusionMonitor {
    public var onChange: (() -> Void)?
    // Also released by the nonisolated deinit; removeObserver is thread-safe.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    public init() {}

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Whether the window is currently considered visible (not occluded).
    public func isVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible)
    }
}

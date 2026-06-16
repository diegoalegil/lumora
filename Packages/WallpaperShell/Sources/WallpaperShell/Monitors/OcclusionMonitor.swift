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

/// Detects when a display's desktop is fully covered by a normal app window — a fullscreen app (the
/// common "watching a video / playing a game" case) or a fully-maximized opaque window — so the live
/// wallpaper behind it can be paused. `occlusionState` is unreliable for a desktop-level, all-Spaces
/// window, so this is a deliberate second detector. A fullscreen app lives on its own Space, so when that
/// Space is active its window shows up in the on-screen window list covering the display; switching back
/// to the desktop drops it from the list — both transitions fire `activeSpaceDidChange`, which already
/// re-evaluates the policy, so resume is immediate. The decision is a pure function of the window
/// rectangles; only the CGWindowList query touches the system.
public struct DesktopCoverDetector {
    /// A candidate covering window: its window level (0 == a normal app window) and global, top-left-origin
    /// bounds (the same coordinate space `CGDisplayBounds` uses).
    public struct WindowRect: Sendable, Equatable {
        public var layer: Int
        public var bounds: CGRect
        public init(layer: Int, bounds: CGRect) { self.layer = layer; self.bounds = bounds }
    }

    /// The fraction of a display a single normal window must cover to count as hiding the wallpaper. A true
    /// fullscreen app covers 100%; the margin tolerates a maximized window that leaves the menu bar.
    public static let defaultCoverage: CGFloat = 0.98

    public init() {}

    /// Whether any normal-level (layer 0) window covers at least `minimumCoverage` of `displayFrame`.
    /// Pure and deterministic — the unit-tested core.
    public static func isCovered(displayFrame: CGRect, windows: [WindowRect],
                                 minimumCoverage: CGFloat = defaultCoverage) -> Bool {
        let area = displayFrame.width * displayFrame.height
        guard area > 0 else { return false }
        for window in windows where window.layer == 0 {
            let intersection = window.bounds.intersection(displayFrame)
            guard !intersection.isNull else { continue }
            if (intersection.width * intersection.height) / area >= minimumCoverage { return true }
        }
        return false
    }

    /// Query the on-screen window list (excluding our own process and desktop elements) and report whether
    /// `displayID`'s desktop is covered. Reading window layer + bounds needs no screen-recording permission.
    @MainActor
    public func isCovered(displayID: CGDirectDisplayID) -> Bool {
        let displayFrame = CGDisplayBounds(displayID)
        let ownPID = getpid()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        var rects: [WindowRect] = []
        for info in infos {
            if let pid = info[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value == ownPID { continue }
            // A near-transparent window (a dimmer/tint overlay) covers geometrically but shows the desktop
            // through it, so it must not pause the wallpaper.
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue < 0.95 { continue }
            guard let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            rects.append(WindowRect(layer: layer.intValue, bounds: bounds))
        }
        return Self.isCovered(displayFrame: displayFrame, windows: rects)
    }
}

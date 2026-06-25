// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSScreen, CGDirectDisplayID, didChangeScreenParameters).
import AppKit

/// Owns one `DesktopWindow` per display, keyed by stable `CGDirectDisplayID`, and keeps the set
/// in sync as displays are connected/disconnected or resolutions change (debounced).
@MainActor
public final class ScreenManager {
    public typealias DisplayID = CGDirectDisplayID

    private let makeWindow: @MainActor (NSScreen) -> DesktopWindow
    public private(set) var windows: [DisplayID: DesktopWindow] = [:]
    /// The frame each window was last set to, so a screen change can resize only the displays that moved
    /// instead of forcing every window to redraw (which a screen-parameters notification would otherwise do
    /// even for an unrelated change on another display).
    private var lastFrames: [DisplayID: CGRect] = [:]

    // Also released by the nonisolated deinit; removeObserver and DispatchWorkItem.cancel are
    // thread-safe.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?
    private nonisolated(unsafe) var debounce: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    /// Called after every reconcile (initial build + each screen change), so owners can sync
    /// per-display state such as renderers and trigger a playback re-evaluation.
    public var onChange: (() -> Void)?

    public init(debounceInterval: TimeInterval = 0.25,
                makeWindow: @escaping @MainActor (NSScreen) -> DesktopWindow) {
        self.makeWindow = makeWindow
        self.debounceInterval = debounceInterval
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        debounce?.cancel()
    }

    /// The stable hardware id for a screen (survives reordering; `nil` only if absent).
    public static func displayID(for screen: NSScreen) -> DisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// A stable string UUID for a display (`CGDisplayCreateUUIDFromDisplayID`) — unlike `CGDirectDisplayID`,
    /// it survives reboots and reconnection, so it's the key the persisted per-monitor assignment uses. Nil if
    /// the display has no UUID (e.g. a virtual/headless display). This bridges the live windows (keyed by
    /// `DisplayID`) to the saved `DisplayAssignment` (keyed by UUID).
    public static func displayUUID(for displayID: DisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    /// Convenience: the stable UUID for a screen, via its hardware id.
    public static func displayUUID(for screen: NSScreen) -> String? {
        displayID(for: screen).flatMap(displayUUID(for:))
    }

    /// Build the initial set of windows and start observing screen changes.
    public func start() {
        guard observer == nil else { return }   // re-entrant start() would orphan the first screen observer
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main thread (queue: .main), so main-actor isolation holds.
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
    }

    /// Tear down all windows and stop observing.
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        debounce?.cancel()
        for (_, win) in windows { win.orderOut(nil) }
        windows.removeAll()
        lastFrames.removeAll()
    }

    private func scheduleRebuild() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Reconcile windows against the current `NSScreen.screens`. A geometry-only change resizes the affected
    /// windows in place (keeping their renderers — no GPU re-init flash); a display whose frame didn't move is
    /// left untouched; only an added/removed display creates or tears down a window.
    public func rebuild() {
        var current: [DisplayID: CGRect] = [:]
        var screensByID: [DisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen) else { continue }
            current[id] = screen.frame
            screensByID[id] = screen
        }

        let diff = ScreenLayoutDiff(from: lastFrames, to: current)
        for id in diff.added {
            guard let screen = screensByID[id] else { continue }
            let win = makeWindow(screen)
            windows[id] = win
            win.orderFrontRegardless()
        }
        for id in diff.resized {
            if let frame = current[id] { windows[id]?.setFrame(frame, display: true) }
        }
        for id in diff.removed {
            windows[id]?.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        lastFrames = current

        onChange?()
    }
}

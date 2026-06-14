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

    /// Build the initial set of windows and start observing screen changes.
    public func start() {
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
    }

    private func scheduleRebuild() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Reconcile windows against the current `NSScreen.screens`.
    public func rebuild() {
        var seen = Set<DisplayID>()
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen) else { continue }
            seen.insert(id)
            if let win = windows[id] {
                win.setFrame(screen.frame, display: true)
            } else {
                let win = makeWindow(screen)
                windows[id] = win
                win.orderFrontRegardless()
            }
        }
        for (id, win) in windows where !seen.contains(id) {
            win.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        onChange?()
    }
}

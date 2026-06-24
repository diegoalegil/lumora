// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSWorkspace notifications). NOTE: these post on
// NSWorkspace.shared.notificationCenter, NOT NotificationCenter.default (a common bug).
import AppKit

/// Watches app-activation, Space changes, and screen sleep/wake. App/Space changes are used as
/// triggers to re-evaluate occlusion; screen sleep is a direct "stop rendering" signal.
@MainActor
public final class WorkspaceMonitor {
    public var onChange: (() -> Void)?
    public private(set) var isDisplayAsleep = false
    /// The screen is locked or the screensaver is running — nothing on the desktop is visible.
    public var isScreenLocked: Bool { screenLocked || screensaverActive }
    private var screenLocked = false
    private var screensaverActive = false

    // Also released by the nonisolated deinit; removeObserver is thread-safe. Lock/screensaver events
    // arrive on the DISTRIBUTED notification center, not NSWorkspace's, so they're tracked separately.
    private nonisolated(unsafe) var tokens: [any NSObjectProtocol] = []
    private nonisolated(unsafe) var distributedTokens: [any NSObjectProtocol] = []

    public init() {}

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.forEach { distributed.removeObserver($0) }
    }

    public func start() {
        guard tokens.isEmpty, distributedTokens.isEmpty else { return }   // already started — don't double-register
        let center = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }

        tokens.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isDisplayAsleep = true
                self?.onChange?()
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isDisplayAsleep = false
                self?.onChange?()
            }
        })

        // Screen lock and screensaver post on the distributed notification center. While either is
        // active the desktop is hidden, so the policy can pause rendering entirely.
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true; self?.onChange?() }
        })
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false; self?.onChange?() }
        })
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensaverActive = true; self?.onChange?() }
        })
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensaverActive = false; self?.onChange?() }
        })
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.forEach { distributed.removeObserver($0) }
        distributedTokens.removeAll()
        // We're no longer observing, so don't keep reporting a stale "asleep / locked / screensaver" state — a
        // restart would otherwise read it as current and wrongly pause rendering.
        isDisplayAsleep = false
        screenLocked = false
        screensaverActive = false
    }
}

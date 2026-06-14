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

    // Also released by the nonisolated deinit; removeObserver is thread-safe.
    private nonisolated(unsafe) var tokens: [any NSObjectProtocol] = []

    public init() {}

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
    }

    public func start() {
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
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }
}

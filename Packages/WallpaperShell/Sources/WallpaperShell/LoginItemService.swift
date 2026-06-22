// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (ServiceManagement / SMAppService, macOS 13+).
// Replaces the deprecated SMLoginItemSetEnabled. Default OFF; registration needs user approval.
import Foundation
import ServiceManagement

@MainActor
public final class LoginItemService {
    public init() {}

    public var status: SMAppService.Status { SMAppService.mainApp.status }
    public var isEnabled: Bool { status == .enabled }
    /// True when macOS is waiting for the user to approve the item in System Settings > Login Items.
    public var requiresApproval: Bool { status == .requiresApproval }

    public func enable() throws { try SMAppService.mainApp.register() }
    public func disable() throws { try SMAppService.mainApp.unregister() }

    /// Open System Settings › General › Login Items so the user can approve a pending registration.
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try enable() } else { try disable() }
    }
}

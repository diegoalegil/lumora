// SPDX-License-Identifier: MIT
// Provenance: clean-room. Observable wrapper around `Preferences` that the settings UI binds to. Any change
// fires `onApply` so the host re-applies it live (Dock icon, login item) and persists it — the write→publish→
// re-apply loop. The wrapping/notification logic is unit-tested; the actual AppKit side-effects are the host's.
import Foundation
import Observation
import WECore

/// Observable preferences for the settings UI. Editing any field publishes the new value through `onApply`,
/// so the host can immediately apply it (e.g. toggle the Dock icon) and save it.
@Observable
public final class PreferencesModel {
    @ObservationIgnored public var onApply: ((Preferences) -> Void)?

    public private(set) var preferences: Preferences

    public init(_ preferences: Preferences = .init(), onApply: ((Preferences) -> Void)? = nil) {
        self.preferences = preferences
        self.onApply = onApply
    }

    public var showDockIcon: Bool {
        get { preferences.showDockIcon }
        set { update { $0.showDockIcon = newValue } }
    }
    public var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set { update { $0.launchAtLogin = newValue } }
    }
    public var playlistPlayback: Bool {
        get { preferences.playlistPlayback }
        set { update { $0.playlistPlayback = newValue } }
    }
    public var activePlaylistID: UUID? {
        get { preferences.activePlaylistID }
        set { update { $0.activePlaylistID = newValue } }
    }

    /// Replace the whole preferences value (e.g. after loading from disk) without re-triggering apply.
    public func set(_ preferences: Preferences) { self.preferences = preferences }

    /// Mutate the preferences and publish the result for live application + persistence.
    private func update(_ mutate: (inout Preferences) -> Void) {
        var next = preferences
        mutate(&next)
        guard next != preferences else { return }   // no-op edits don't re-apply
        preferences = next
        onApply?(next)
    }
}

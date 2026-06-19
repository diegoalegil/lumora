// SPDX-License-Identifier: MIT
// Provenance: clean-room (AppKit + SwiftUI hosting per Apple docs). Hosts the SwiftUI settings UI in a real
// window opened from the menu bar. Pure glue — the models it shows are unit-tested in WallpaperShell.
import AppKit
import SwiftUI
import WallpaperShell

/// Owns the settings window (a single, reused `NSWindow` hosting `SettingsView`) and shows it on demand.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: PlaylistStore
    private let preferences: PreferencesModel
    private let libraryItems: () -> [WallpaperListItem]

    init(store: PlaylistStore, preferences: PreferencesModel, libraryItems: @escaping () -> [WallpaperListItem]) {
        self.store = store
        self.preferences = preferences
        self.libraryItems = libraryItems
    }

    /// Bring the settings window to the front, creating it on first use.
    func show() {
        if window == nil {
            let root = SettingsView(store: store, preferences: preferences, libraryItems: libraryItems())
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Lumora"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. Hosts the SwiftUI `LibraryBrowserView` in a standard resizable window. The model and
// store are owned by the AppDelegate so the window can be opened, closed and reopened without losing state.
import AppKit
import SwiftUI
import WallpaperShell

@MainActor
final class LibraryWindowController: NSWindowController {
    private let model: LibraryBrowserModel
    private let store: PlaylistStore

    init(model: LibraryBrowserModel, store: PlaylistStore,
         onApply: @escaping (LibraryEntry) -> Void, onReveal: @escaping (LibraryEntry) -> Void,
         makePropertiesModel: @escaping (LibraryEntry) -> WallpaperPropertiesModel? = { _ in nil }) {
        self.model = model
        self.store = store

        let root = LibraryBrowserView(model: model, store: store, onApply: onApply, onReveal: onReveal,
                                      makePropertiesModel: makePropertiesModel)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Lumora Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 1040, height: 660))
        window.center()
        window.setFrameAutosaveName("LumoraLibraryWindow")
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Bring the window forward (activating the app so a menu-bar-only launch can show a real window).
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

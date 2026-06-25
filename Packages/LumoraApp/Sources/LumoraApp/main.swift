// SPDX-License-Identifier: MIT
// Provenance: clean-room. Entry point: a background, menu-bar-only app.
import AppKit

let app = NSApplication.shared
// Menu-bar only: no Dock icon, no main menu (equivalent to LSUIElement when run unbundled).
app.setActivationPolicy(.accessory)

if SnapshotRunner.isRequested {
    // Dev-only: render a SwiftUI scene to PNG and exit. No AppDelegate, so no Steam scan / desktop windows.
    SnapshotRunner.run()
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

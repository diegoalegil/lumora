// SPDX-License-Identifier: MIT
// Provenance: clean-room. Entry point: a background, menu-bar-only app.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon, no main menu (equivalent to LSUIElement when run unbundled).
app.setActivationPolicy(.accessory)
app.run()

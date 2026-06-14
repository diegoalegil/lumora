// SPDX-License-Identifier: MIT
// Provenance: clean-room. Entry point: a background (accessory) menu-bar agent.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Background agent: no Dock icon, no main menu (equivalent to LSUIElement when run unbundled).
app.setActivationPolicy(.accessory)
app.run()

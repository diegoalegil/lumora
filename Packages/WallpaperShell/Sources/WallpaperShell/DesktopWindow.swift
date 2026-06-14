// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSWindow, CGWindowLevelForKey, collectionBehavior).
// The single place the "own the desktop" window recipe lives, so per-OS tweaks are localized.
import AppKit

/// A borderless, transparent, click-through window pinned at desktop level on every Space.
/// One per display.
@MainActor
public final class DesktopWindow: NSWindow {

    /// Where the wallpaper sits relative to the Finder desktop icons.
    public enum Placement: Sendable {
        /// Below the icons — Finder icons render on top (the usual, least-surprising choice).
        case behindIcons
        /// Above the icons — covers them. Use only when the design wants icon-free wallpaper.
        case aboveIcons
    }

    /// When interactive, the window accepts mouse events and can become key (opt-in only;
    /// macOS Sonoma+ "click wallpaper to reveal desktop" can otherwise intercept clicks).
    public var isInteractive: Bool = false {
        didSet { ignoresMouseEvents = !isInteractive }
    }

    public override var canBecomeKey: Bool { isInteractive }
    public override var canBecomeMain: Bool { false }

    public init(screen: NSScreen, placement: Placement = .behindIcons) {
        // Use the designated initializer (no `screen:`); the screen is selected by setting the
        // frame to the screen's global rect below.
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        switch placement {
        case .behindIcons:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        case .aboveIcons:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }

        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        setFrame(screen.frame, display: false)
    }
}

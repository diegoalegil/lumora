// SPDX-License-Identifier: MIT
// Provenance: clean-room. The Phase 0 "you own the desktop" renderer: a flat color, used to
// prove the window/host/screen plumbing before any real player exists.
import AppKit
import WECore

@MainActor
public final class SolidColorRenderer: WallpaperRenderer {
    private let color: NSColor
    private var view: NSView?

    public init(color: NSColor = .black) {
        self.color = color
    }

    public func makeHostedView() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        view = v
        return v
    }

    public func load(_ wallpaper: ResolvedWallpaper) throws { /* nothing to load */ }
    public func resume() { /* static */ }
    public func pause() { /* static */ }
    public func tearDown() {
        view?.removeFromSuperview()
        view = nil
    }
}

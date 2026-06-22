// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (NSView, Auto Layout). A live wallpaper mounted on a display for the
// DisplaySwitcher: an engine renderer hosted in a full-frame container view whose opacity the cross-fade
// drives. Two of these overlap on one display during a transition. The desktop is only ever touched on the
// main thread, so the WallpaperSurface methods assume main-actor isolation.
import AppKit
import WECore

/// A wallpaper surface backed by a real engine renderer in a container view added to the display's window.
/// A failed resolve/load shows nothing (an empty, transparent surface) rather than crashing — render-or-degrade.
@MainActor
public final class RendererSurface: WallpaperSurface {
    public let reference: WallpaperReference
    private let renderer: (any WallpaperRenderer)?
    private let container: NSView

    /// Build and mount a surface inside `parent` (the display's content view). `resolved` is the wallpaper the
    /// reference points at (nil if it isn't in the library); `factory` builds the engine renderer.
    public init(reference: WallpaperReference, resolved: ResolvedWallpaper?,
                factory: WallpaperPlayerFactory, parent: NSView) {
        self.reference = reference

        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false

        var renderer: (any WallpaperRenderer)?
        if let resolved, let made = try? factory.makeRenderer(for: resolved) {
            do {
                try made.load(resolved)
                let view = made.makeHostedView()
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    view.topAnchor.constraint(equalTo: container.topAnchor),
                    view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                made.resume()
                renderer = made
            } catch {
                made.tearDown()   // load failed → discard, show an empty surface
            }
        }
        self.renderer = renderer

        parent.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            container.topAnchor.constraint(equalTo: parent.topAnchor),
            container.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        self.container = container
    }

    public func setOpacity(_ opacity: Double) {
        container.alphaValue = CGFloat(max(0, min(1, opacity)))
    }

    public func teardown() {
        renderer?.tearDown()
        container.removeFromSuperview()
    }

    /// Forward a playback directive (pause/fps) to the live renderer.
    public func apply(_ directive: PlaybackDirective) { renderer?.apply(directive) }
}

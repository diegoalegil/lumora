// SPDX-License-Identifier: MIT
// Provenance: clean-room. The single seam every player conforms to and the shell hosts.
import AppKit

/// The one protocol the desktop shell talks to. Video, Web, and Scene players each conform to
/// it; the shell hosts the returned `NSView` and pushes lifecycle/playback directives without
/// knowing anything about AVFoundation / WebKit / Metal.
@MainActor
public protocol WallpaperRenderer: AnyObject {
    /// The view to embed in the desktop window. Stable for the renderer's lifetime.
    func makeHostedView() -> NSView

    /// Load (or reload) the wallpaper's content. May throw on unreadable/unsupported assets.
    func load(_ wallpaper: ResolvedWallpaper) throws

    /// Resume active playback (e.g. after returning from an occluded state).
    func resume()

    /// Pause playback while keeping resources warm.
    func pause()

    /// Apply a playback directive (enable/disable rendering + target frame rate).
    func apply(_ directive: PlaybackDirective)

    /// Release all resources; the renderer is not reused afterwards.
    func tearDown()
}

public extension WallpaperRenderer {
    /// Default mapping of a directive onto resume/pause; renderers can override `apply` for
    /// finer control (e.g. clamping MTKView.preferredFramesPerSecond).
    func apply(_ directive: PlaybackDirective) {
        if directive.renderingEnabled { resume() } else { pause() }
    }
}

/// Creates the concrete renderer for a resolved wallpaper. Implemented by WEPlayers and wired
/// in by the App, so WECore stays free of AVFoundation/WebKit/Metal dependencies.
@MainActor
public protocol WallpaperPlayerFactory {
    func makeRenderer(for wallpaper: ResolvedWallpaper) throws -> any WallpaperRenderer
}

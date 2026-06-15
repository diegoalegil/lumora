// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (WKWebView, WKWebViewConfiguration). Loads a web
// wallpaper's index.html from disk with a transparent backdrop and autoplaying media.
import AppKit
import WebKit
import WECore

public enum WebPlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedType(WallpaperType)

    public var description: String {
        switch self {
        case .unsupportedType(let type):
            return "WebPlayer cannot play a '\(type.rawValue)' wallpaper."
        }
    }
}

/// Renders a `.web` wallpaper by loading its `index.html` in a WKWebView behind the desktop icons.
@MainActor
public final class WebPlayer: WallpaperRenderer {
    /// The wallpaper type this renderer handles.
    public static let supportedType: WallpaperType = .web

    private let webView: WKWebView
    private var navigationGuard: NavigationGuard?

    public init() {
        let configuration = WKWebViewConfiguration()
        // A wallpaper should animate on its own — don't gate background video/audio on a click.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Define WE's web API before the wallpaper runs so it doesn't ReferenceError on the hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(source: WEWebBridge.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Let the desktop show through any transparent regions instead of an opaque white page.
        webView.underPageBackgroundColor = .clear
    }

    public func makeHostedView() -> NSView { webView }

    public func load(_ wallpaper: ResolvedWallpaper) throws {
        guard wallpaper.type == Self.supportedType else {
            throw WebPlayerError.unsupportedType(wallpaper.type)
        }
        // The page is untrusted: confine its navigations to its own folder before loading it, so a
        // redirect or remote frame to the network is cancelled.
        let navigationGuard = NavigationGuard(policy: WallpaperNavigationPolicy(confinedTo: wallpaper.ref.folderURL))
        webView.navigationDelegate = navigationGuard
        self.navigationGuard = navigationGuard
        // Grant read access to the wallpaper folder so the page can reach its css/js/image assets.
        webView.loadFileURL(wallpaper.mainFileURL, allowingReadAccessTo: wallpaper.ref.folderURL)
    }

    public func resume() { webView.setAllMediaPlaybackSuspended(false, completionHandler: nil) }

    public func pause() { webView.setAllMediaPlaybackSuspended(true, completionHandler: nil) }

    public func apply(_ directive: PlaybackDirective) {
        // Best-effort: this pauses/resumes <video>/<audio>. Throttling JS/canvas animation needs the
        // WE JS bridge and lands with it.
        if directive.renderingEnabled { resume() } else { pause() }
    }

    public func tearDown() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }
}

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
    /// Compiled once per process: a content-blocking rule that drops every remote (http/https/ws/ftp) load.
    private static var blockRemoteRules: WKContentRuleList?

    /// Injected before any page script (all frames): removes the WebRTC constructors so an untrusted wallpaper
    /// can't open a peer connection the URL-scheme content rule cannot block. The properties are made
    /// non-writable/non-configurable so page code can't restore them.
    public static let disableWebRTCScript = """
    (function () {
        'use strict';
        var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection',
                     'RTCDataChannel', 'RTCSessionDescription', 'RTCIceCandidate', 'RTCRtpSender'];
        for (var i = 0; i < names.length; i++) {
            try { Object.defineProperty(window, names[i], { value: undefined, writable: false, configurable: false }); }
            catch (e) {}
        }
    })();
    """

    public init() {
        let configuration = WKWebViewConfiguration()
        // A wallpaper should animate on its own — don't gate background video/audio on a click.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // An ephemeral store: an untrusted wallpaper gets no persistent cookies/localStorage/cache to stage
        // tracking state in across launches.
        configuration.websiteDataStore = .nonPersistent()
        // Define WE's web API before the wallpaper runs so it doesn't ReferenceError on the hooks.
        configuration.userContentController.addUserScript(
            WKUserScript(source: WEWebBridge.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // The remote-load content rule filters by URL scheme, so it can't see WebRTC: an RTCPeerConnection +
        // data channel rides UDP/STUN/TURN, not http/ws, and would stay open as an exfiltration path. A
        // wallpaper has no legitimate use for peer connections, so neuter the APIs in every frame before any
        // page script runs. (EventSource/fetch/XHR/WebSocket all use blocked schemes, so the content rule
        // already covers them; WebRTC is the only hole it structurally cannot close.)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.disableWebRTCScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        // Make the wallpaper's animation loop pausable so an occluded/asleep web wallpaper stops spinning its
        // requestAnimationFrame (canvas/WebGL/JS) loop at full rate instead of only muting <video>/<audio>.
        configuration.userContentController.addUserScript(
            WKUserScript(source: WEWebBridge.animationSuspendScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
        // The navigation delegate only sees navigations, not subresource loads (fetch/XHR/WebSocket/<img>),
        // which are the real exfiltration path. Block all remote loads with a content rule before the page
        // runs; only then load it. The rule compiles asynchronously, so defer the load into the completion.
        let target = wallpaper.mainFileURL, folder = wallpaper.ref.folderURL
        Self.withBlockRemoteRules { [weak self] rules in
            guard let self else { return }
            if let rules {
                // Loading a second wallpaper on the same player would otherwise stack a duplicate rule list;
                // the only content rules here are these block-remote ones, so clearing first is safe.
                self.webView.configuration.userContentController.removeAllContentRuleLists()
                self.webView.configuration.userContentController.add(rules)
            }
            // Grant read access to the wallpaper folder so the page can reach its css/js/image assets.
            self.webView.loadFileURL(target, allowingReadAccessTo: folder)
        }
    }

    /// Compile (once) and hand back the remote-blocking rule list. Loads still proceed if compilation fails,
    /// falling back to the navigation guard alone rather than refusing to show the wallpaper.
    private static func withBlockRemoteRules(_ completion: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let rules = blockRemoteRules { completion(rules); return }
        let source = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lumora-block-remote",
                                                                encodedContentRuleList: source) { list, error in
            if let error { NSLog("Lumora: remote-block rules failed to compile (\(error)); navigation guard only") }
            blockRemoteRules = list
            completion(list)
        }
    }

    public func resume() {
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        setAnimationPaused(false)
    }

    public func pause() {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        setAnimationPaused(true)
    }

    /// Toggle the injected requestAnimationFrame gate (see `WEWebBridge.animationSuspendScript`) so an
    /// occluded wallpaper's canvas/WebGL/JS loop stops, not just its media. Guarded so it's a no-op if the
    /// page hasn't installed the hook yet (it runs at document-start, so it's present once anything loads).
    private func setAnimationPaused(_ paused: Bool) {
        webView.evaluateJavaScript(
            "window.__lumoraSetAnimationPaused && window.__lumoraSetAnimationPaused(\(paused));",
            completionHandler: nil)
    }

    public func apply(_ directive: PlaybackDirective) {
        // Pauses/resumes <video>/<audio> AND the page's requestAnimationFrame animation loop, so an
        // occluded/asleep web wallpaper stops consuming CPU/GPU instead of spinning invisibly.
        if directive.renderingEnabled { resume() } else { pause() }
    }

    public func tearDown() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (WKNavigationDelegate). Confines an untrusted wallpaper page
// to its own local content so it cannot navigate the desktop background out to the network.
import Foundation
import WebKit

/// Decides whether a wallpaper web view may follow a navigation. A web wallpaper is third-party
/// HTML/JS; with no policy its script could redirect the view to a remote site or embed a remote
/// frame, turning an always-on background into a telemetry/exfiltration channel. The policy permits
/// only local content (the wallpaper's own `file://` assets, or a private scheme) and blocks anything
/// that reaches the network or escapes the allowed folder. It is a pure value so it can be tested
/// without a live web view.
public struct WallpaperNavigationPolicy: Sendable, Equatable {
    /// Schemes that reach the network — always blocked.
    private static let remoteSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp"]

    private let allowedDirectoryPath: String?

    /// - Parameter directory: when set, a `file://` navigation must resolve inside it. Pass `nil` when
    ///   the page is served over a private scheme whose handler already constrains what it serves.
    public init(confinedTo directory: URL? = nil) {
        self.allowedDirectoryPath = directory?.standardizedFileURL.path
    }

    /// Whether navigating to `url` is allowed.
    public func allows(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return true }  // about:blank et al.
        if Self.remoteSchemes.contains(scheme) { return false }
        if scheme == "file", let dir = allowedDirectoryPath {
            // Use standardizedFileURL, not standardized: `standardized` collapses only the LITERAL `.`/`..`
            // in the URL string without percent-decoding first, so a `%2e%2e` escape survives it and `.path`
            // then decodes it to `..` — a traversal `hasPrefix(dir)` would wrongly admit. standardizedFileURL
            // builds from the decoded file path, collapses `..`, and resolves symlinks for existing components.
            let p = url.standardizedFileURL.path
            return p == dir || p.hasPrefix(dir + "/")
        }
        return true  // local custom scheme, data:, or an unconfined file load
    }
}

/// Adapts `WallpaperNavigationPolicy` to `WKNavigationDelegate`. A web view holds its navigation
/// delegate weakly, so the owning player must retain this object for the lifetime of the view.
@MainActor
final class NavigationGuard: NSObject, WKNavigationDelegate {
    private let policy: WallpaperNavigationPolicy

    init(policy: WallpaperNavigationPolicy) {
        self.policy = policy
    }

    // The decisionHandler closure type must match WKNavigationDelegate's optional requirement EXACTLY
    // (`@MainActor @Sendable`); a near-miss isn't seen as @objc, so WebKit never calls it and the policy goes
    // inert — a web wallpaper could then navigate to the network unchecked.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy.allows(navigationAction.request.url) ? .allow : .cancel)
    }
}

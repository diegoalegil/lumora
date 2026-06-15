// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (WKWebView, WKURLSchemeHandler). Plays a video whose codec
// AVFoundation can't decode (e.g. VP8/VP9 .webm) by feeding it to a full-screen <video> element and
// serving the local file over a private URL scheme — no temp copies, no folder pollution.
import AppKit
import WebKit
import WECore

/// Renders a `.video` wallpaper through WebKit's media stack, for containers AVFoundation can't open.
@MainActor
public final class VideoFallbackPlayer: WallpaperRenderer {
    /// The wallpaper type this renderer handles.
    public static let supportedType: WallpaperType = .video

    private let webView: WKWebView
    private let handler = AssetSchemeHandler()

    public init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
    }

    public func makeHostedView() -> NSView { webView }

    public func load(_ wallpaper: ResolvedWallpaper) throws {
        guard wallpaper.type == Self.supportedType else {
            throw VideoPlayerError.unsupportedType(wallpaper.type)
        }
        let videoURL = "\(AssetSchemeHandler.scheme)://asset/video"
        let mime = VideoFallbackHTML.mimeType(forExtension: wallpaper.mainFileURL.pathExtension)
        handler.configure(fileURL: wallpaper.mainFileURL,
                          html: VideoFallbackHTML.page(srcURL: videoURL, mimeType: mime))
        // Load the page through the scheme so its origin matches the video request (same-origin).
        if let pageURL = URL(string: "\(AssetSchemeHandler.scheme)://asset/index.html") {
            webView.load(URLRequest(url: pageURL))
        }
    }

    public func resume() { webView.setAllMediaPlaybackSuspended(false, completionHandler: nil) }

    public func pause() { webView.setAllMediaPlaybackSuspended(true, completionHandler: nil) }

    public func apply(_ directive: PlaybackDirective) {
        if directive.renderingEnabled { resume() } else { pause() }
    }

    public func tearDown() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }
}

/// Serves the wallpaper's HTML page and the local video bytes over a private scheme so the WebKit
/// `<video>` element can read a file outside any granted directory.
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lumora-asset"

    private var fileURL: URL?
    private var html = ""

    func configure(fileURL: URL, html: String) {
        self.fileURL = fileURL
        self.html = html
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let path = urlSchemeTask.request.url?.path ?? ""
        if path.hasSuffix("index.html") {
            respond(urlSchemeTask, data: Data(html.utf8), mime: "text/html")
        } else if let fileURL, let data = try? Data(contentsOf: fileURL) {
            respond(urlSchemeTask, data: data, mime: VideoFallbackHTML.mimeType(forExtension: fileURL.pathExtension))
        } else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, data: Data, mime: String) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://asset/")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

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
    // The page only ever loads over the private asset scheme; block any navigation the wallpaper's
    // markup attempts to the network. Retained because `navigationDelegate` is weak.
    private let navigationGuard = NavigationGuard(policy: WallpaperNavigationPolicy())

    public init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
        webView.navigationDelegate = navigationGuard
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
        handler.release()   // drop the memory-mapped video
    }
}

/// Parses an HTTP `Range: bytes=START-[END]` or suffix `bytes=-N` header into a half-open byte range within a
/// file of `total` bytes (nil for anything malformed or out of range). A pure value, tested without WebKit.
public enum AssetByteRange {
    public static func parse(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0, let spec = header.split(separator: "=").last.map(String.init) else { return nil }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        // Suffix range `bytes=-N` (RFC 7233): the last N bytes, clamped to the file start for an over-large N.
        if parts.count == 2, parts[0].isEmpty, let len = Int(parts[1]), len > 0 {
            return max(0, total - len) ..< total
        }
        guard let start = parts.first.flatMap({ Int($0) }), start >= 0, start < total else { return nil }
        let end = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
        let clampedEnd = min(max(end, start), total - 1)
        return start ..< (clampedEnd + 1)
    }
}

/// Serves the wallpaper's HTML page and the local video bytes over a private scheme so the WebKit
/// `<video>` element can read a file outside any granted directory.
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lumora-asset"

    private var fileURL: URL?
    private var html = ""
    // The file is memory-mapped once when the wallpaper loads, not on every Range request: WebKit's <video>
    // streams a clip with many small Range requests, and re-establishing the mmap each time is needless
    // per-request main-thread work. Re-mapped on each configure() so the mapping tracks the active wallpaper.
    private var fileData: Data?
    private var mime = "application/octet-stream"

    func configure(fileURL: URL, html: String) {
        self.fileURL = fileURL
        self.html = html
        self.fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        self.mime = VideoFallbackHTML.mimeType(forExtension: fileURL.pathExtension)
    }

    /// Drop the memory-mapped file when the player tears down, so an unmounted wallpaper doesn't keep a
    /// (possibly large) video mapped in.
    func release() {
        fileURL = nil
        fileData = nil
        html = ""
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let path = urlSchemeTask.request.url?.path ?? ""
        if path.hasSuffix("index.html") {
            respond(urlSchemeTask, data: Data(html.utf8), mime: "text/html")
        } else if let data = fileData {
            // The file is already memory-mapped (configure()); honour the <video> element's Range requests so
            // a large clip streams a window at a time and seeking works, without re-mapping per request.
            if let header = urlSchemeTask.request.value(forHTTPHeaderField: "Range") {
                if let range = AssetByteRange.parse(header, total: data.count) {
                    respond(urlSchemeTask, data: data.subdata(in: range), mime: mime, partialOf: data.count, start: range.lowerBound)
                } else {
                    // A Range header that can't be satisfied (e.g. `bytes=<fileSize>-`, an end-of-file probe):
                    // RFC 7233 wants 416, not the whole clip streamed back — which for a hundreds-of-MB webm
                    // fallback would hand WebKit the entire mapped file for a request that asked for nothing.
                    respondUnsatisfiableRange(urlSchemeTask, total: data.count)
                }
            } else {
                respond(urlSchemeTask, data: data, mime: mime)
            }
        } else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    /// Send a response. `partialOf` (the full length) marks it a 206 Partial Content with a Content-Range,
    /// otherwise a 200 that advertises Accept-Ranges so the client knows it may request windows next time.
    private func respond(_ task: any WKURLSchemeTask, data: Data, mime: String, partialOf total: Int? = nil, start: Int = 0) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://asset/")!
        var headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Accept-Ranges": "bytes"]
        var status = 200
        if let total {
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(start + data.count - 1)/\(total)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Reply 416 Range Not Satisfiable with an empty body and a `Content-Range: bytes (unsatisfied)/total` per RFC 7233.
    private func respondUnsatisfiableRange(_ task: any WKURLSchemeTask, total: Int) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://asset/")!
        let headers = ["Content-Range": "bytes */\(total)", "Content-Length": "0", "Accept-Ranges": "bytes"]
        let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didFinish()
    }
}

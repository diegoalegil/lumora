// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of WEPlayers headless logic (CLT-only equivalent of unit
// tests). The AVKit/AppKit rendering path is validated by running LumoraApp.
import Foundation
import JavaScriptCore
import WECore
import WEPlayers

func resolved(_ type: WallpaperType, _ name: String, file: String = "main.mp4") -> ResolvedWallpaper {
    let folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    let manifest = ProjectManifest(title: name, rawType: type.rawValue, file: file)
    let ref = WallpaperRef(folderURL: folder, manifest: manifest)
    return ResolvedWallpaper(
        ref: ref,
        type: type,
        manifest: manifest,
        mainFileURL: folder.appendingPathComponent(file)
    )
}

Check.section("VideoFormatSupport")
Check.that("mp4 is native", VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.mp4")))
Check.that("mov is native", VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.mov")))
Check.that("uppercase extension is native", VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/A.MP4")))
Check.that("webm is not native", !VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.webm")))
Check.that("webm is fallback-playable", VideoFormatSupport.isFallbackPlayable(URL(fileURLWithPath: "/x/a.webm")))
Check.that("mkv is fallback-playable", VideoFormatSupport.isFallbackPlayable(URL(fileURLWithPath: "/x/a.mkv")))
Check.that("mp4 is not fallback", !VideoFormatSupport.isFallbackPlayable(URL(fileURLWithPath: "/x/a.mp4")))
Check.that("webm is playable via fallback", VideoFormatSupport.isPlayable(URL(fileURLWithPath: "/x/a.webm")))
Check.that("mp4 is playable", VideoFormatSupport.isPlayable(URL(fileURLWithPath: "/x/a.mp4")))
Check.that("avi is not playable at all", !VideoFormatSupport.isPlayable(URL(fileURLWithPath: "/x/a.avi")))
Check.that("no extension is not playable", !VideoFormatSupport.isPlayable(URL(fileURLWithPath: "/x/a")))

Check.section("PlayableWallpapers.isPlayable")
Check.that("mp4 video is playable", PlayableWallpapers.isPlayable(resolved(.video, "v", file: "a.mp4")))
Check.that("webm video is playable via fallback", PlayableWallpapers.isPlayable(resolved(.video, "v", file: "a.webm")))
Check.that("avi video is not playable", !PlayableWallpapers.isPlayable(resolved(.video, "v", file: "a.avi")))
Check.that("web is playable", PlayableWallpapers.isPlayable(resolved(.web, "w", file: "index.html")))
Check.that("scene is playable via ScenePlayer", PlayableWallpapers.isPlayable(resolved(.scene, "s", file: "scene.pkg")))

Check.section("PlayableWallpapers.all / active")
let library = [
    resolved(.video, "vavi", file: "a.avi"),      // excluded (no decoder for avi)
    resolved(.scene, "s", file: "scene.pkg"),     // playable via ScenePlayer
    resolved(.video, "vweb", file: "a.webm"),     // playable via WebKit fallback
    resolved(.web, "web1", file: "index.html"),
    resolved(.video, "vmp4", file: "b.mp4"),
]
let playable = PlayableWallpapers.all(in: library)
Check.that("all keeps only playable, in order", playable.map(\.ref.id) == ["s", "vweb", "web1", "vmp4"])
Check.that("active picks first playable when no selection",
           PlayableWallpapers.active(in: library, selectedID: nil)?.ref.id == "s")
Check.that("active honours a valid selection",
           PlayableWallpapers.active(in: library, selectedID: "vmp4")?.ref.id == "vmp4")
Check.that("active honours a scene selection",
           PlayableWallpapers.active(in: library, selectedID: "s")?.ref.id == "s")
Check.that("active falls back when selection is unplayable (avi)",
           PlayableWallpapers.active(in: library, selectedID: "vavi")?.ref.id == "s")
Check.that("active falls back when selection is unknown",
           PlayableWallpapers.active(in: library, selectedID: "nope")?.ref.id == "s")
Check.that("active is nil when nothing is playable",
           PlayableWallpapers.active(in: [resolved(.video, "x", file: "a.avi")], selectedID: nil) == nil)

Check.section("VideoFallbackHTML")
Check.that("webm mime", VideoFallbackHTML.mimeType(forExtension: "webm") == "video/webm")
Check.that("uppercase WEBM mime", VideoFallbackHTML.mimeType(forExtension: "WEBM") == "video/webm")
Check.that("mp4 mime", VideoFallbackHTML.mimeType(forExtension: "mp4") == "video/mp4")
Check.that("unknown mime", VideoFallbackHTML.mimeType(forExtension: "xyz") == "application/octet-stream")
let fallbackPage = VideoFallbackHTML.page(srcURL: "lumora-asset://asset/video", mimeType: "video/webm")
Check.that("page references the src", fallbackPage.contains("lumora-asset://asset/video"))
Check.that("page sets the type", fallbackPage.contains("video/webm"))
Check.that("page loops and is muted", fallbackPage.contains("loop") && fallbackPage.contains("muted"))

Check.section("WEWebBridge")
Check.that("defines the audio listener hook", WEWebBridge.bootstrapScript.contains("wallpaperRegisterAudioListener"))
Check.that("defines a media listener hook", WEWebBridge.bootstrapScript.contains("wallpaperRegisterMediaStatusListener"))
Check.that("defines the random-file hook", WEWebBridge.bootstrapScript.contains("wallpaperRequestRandomFileForProperty"))
Check.that("does not define wallpaperPropertyListener (the wallpaper owns it)",
           !WEWebBridge.bootstrapScript.contains("window.wallpaperPropertyListener ="))

// The animation-suspend shim must gate requestAnimationFrame: pass through when running, queue while paused,
// and flush the queue to the real rAF on resume — so an occluded web wallpaper's loop stops, then restarts
// exactly where it left off with no visible change when running. Verified deterministically in JSContext.
if let ctx = JSContext() {
    ctx.evaluateScript("var __sched = 0; var window = {}; window.requestAnimationFrame = function (cb) { __sched++; };")
    ctx.evaluateScript(WEWebBridge.animationSuspendScript)
    ctx.evaluateScript("window.requestAnimationFrame(function () {});")          // running → passes through
    Check.that("rAF passes through to the real scheduler while running",
               ctx.evaluateScript("__sched").toInt32() == 1)
    ctx.evaluateScript("window.__lumoraSetAnimationPaused(true); window.requestAnimationFrame(function () {}); window.requestAnimationFrame(function () {});")
    Check.that("rAF is queued (not scheduled) while paused",
               ctx.evaluateScript("__sched").toInt32() == 1)
    ctx.evaluateScript("window.__lumoraSetAnimationPaused(false);")
    Check.that("queued frames flush to the real scheduler on resume",
               ctx.evaluateScript("__sched").toInt32() == 3)
    ctx.evaluateScript("window.requestAnimationFrame(function () {});")          // resumed → passes through again
    Check.that("rAF passes through again after resume",
               ctx.evaluateScript("__sched").toInt32() == 4)
} else {
    Check.that("a JSContext is available to verify the animation-suspend shim", false)
}

Check.section("WebPlayer hardening")
// The URL-scheme content rule can't block WebRTC, so the page hardening script must neuter the peer-connection
// APIs (non-configurable) before any page script runs — a regression here re-opens an exfiltration channel.
Check.that("disables RTCPeerConnection", WebPlayer.disableWebRTCScript.contains("RTCPeerConnection"))
Check.that("also disables the webkit-prefixed constructor", WebPlayer.disableWebRTCScript.contains("webkitRTCPeerConnection"))
Check.that("makes the override non-configurable (page can't restore it)",
           WebPlayer.disableWebRTCScript.contains("configurable: false"))

Check.section("Players")
Check.that("VideoPlayer handles the video type", VideoPlayer.supportedType == .video)
Check.that("VideoFallbackPlayer handles the video type", VideoFallbackPlayer.supportedType == .video)
Check.that("WebPlayer handles the web type", WebPlayer.supportedType == .web)

Check.section("DefaultWallpaperPlayerFactory routing")
Check.that("native video container routes to the AVFoundation player",
           DefaultWallpaperPlayerFactory.kind(for: resolved(.video, "v", file: "a.mp4")) == .nativeVideo)
Check.that("mov also routes to the native player",
           DefaultWallpaperPlayerFactory.kind(for: resolved(.video, "v", file: "a.mov")) == .nativeVideo)
Check.that("a webm video routes to the WebKit <video> fallback",
           DefaultWallpaperPlayerFactory.kind(for: resolved(.video, "v", file: "a.webm")) == .fallbackVideo)
Check.that("a web wallpaper routes to the web player",
           DefaultWallpaperPlayerFactory.kind(for: resolved(.web, "w", file: "index.html")) == .web)
Check.that("a scene wallpaper routes to the scene player",
           DefaultWallpaperPlayerFactory.kind(for: resolved(.scene, "s", file: "scene.pkg")) == .scene)

Check.section("WallpaperNavigationPolicy")
let wallpaperFolder = URL(fileURLWithPath: "/Steam/workshop/431960/123", isDirectory: true)
let confined = WallpaperNavigationPolicy(confinedTo: wallpaperFolder)
Check.that("allows the local index.html", confined.allows(wallpaperFolder.appendingPathComponent("index.html")))
Check.that("allows a nested local asset", confined.allows(wallpaperFolder.appendingPathComponent("js/app.js")))
Check.that("blocks navigation to https", !confined.allows(URL(string: "https://evil.example/x")))
Check.that("blocks navigation to http", !confined.allows(URL(string: "http://evil.example/x")))
Check.that("blocks a websocket", !confined.allows(URL(string: "wss://evil.example/x")))
Check.that("blocks a file outside the folder", !confined.allows(URL(fileURLWithPath: "/etc/passwd")))
Check.that("blocks a prefix-sibling folder", !confined.allows(URL(fileURLWithPath: "/Steam/workshop/431960/123-evil/x.html")))
// A percent-encoded `..` traversal must NOT escape: `standardized` leaves %2e%2e uncollapsed (it decodes
// only after, in .path), so the old check admitted this; standardizedFileURL decodes-then-collapses first.
Check.that("blocks a percent-encoded ../ traversal",
           !confined.allows(URL(string: "file:///Steam/workshop/431960/123/%2e%2e/%2e%2e/secret/x.html")))
Check.that("blocks a plain ../ traversal",
           !confined.allows(URL(string: "file:///Steam/workshop/431960/123/../../secret/x.html")))
Check.that("allows a percent-encoded path that stays inside the folder",
           confined.allows(URL(string: "file:///Steam/workshop/431960/123/a%20b/app.js")))
Check.that("allows about:blank (teardown)", confined.allows(URL(string: "about:blank")))
let schemeServed = WallpaperNavigationPolicy()
Check.that("allows the private asset scheme", schemeServed.allows(URL(string: "lumora-asset://asset/index.html")))
Check.that("still blocks remote without confinement", !schemeServed.allows(URL(string: "https://evil.example")))

Check.section("AssetByteRange (video fallback Range serving)")
Check.that("open-ended range runs to EOF", AssetByteRange.parse("bytes=100-", total: 1000) == 100 ..< 1000)
Check.that("closed range is inclusive", AssetByteRange.parse("bytes=0-99", total: 1000) == 0 ..< 100)
Check.that("end past EOF is clamped", AssetByteRange.parse("bytes=900-5000", total: 1000) == 900 ..< 1000)
Check.that("start at/past EOF is rejected", AssetByteRange.parse("bytes=1000-", total: 1000) == nil)
Check.that("malformed header is rejected", AssetByteRange.parse("bytes=abc-def", total: 1000) == nil)
Check.that("non-range header is rejected", AssetByteRange.parse("garbage", total: 1000) == nil)
Check.that("empty file serves no range", AssetByteRange.parse("bytes=0-", total: 0) == nil)
// RFC 7233 suffix range: the last N bytes, clamped to the file start when N exceeds the length.
Check.that("suffix range returns the last N bytes", AssetByteRange.parse("bytes=-500", total: 1000) == 500 ..< 1000)
Check.that("over-large suffix clamps to the file start", AssetByteRange.parse("bytes=-5000", total: 1000) == 0 ..< 1000)
Check.that("a bare suffix dash is rejected", AssetByteRange.parse("bytes=-", total: 1000) == nil)

Check.section("ScenePlayer frame pacing")
// The playback policy's targetFPS must actually drive the scene loop: 60 active, 30 on battery / low-power,
// and 0 (paused / occluded) means no continuous loop at all. Previously the loop was a hardcoded 30fps, so
// the battery throttle did nothing and the active case under-rendered.
Check.that("a 60fps directive drives a 1/60s loop interval", ScenePlayer.frameInterval(forTargetFPS: 60) == 1.0 / 60.0)
Check.that("a battery 30fps throttle drives a 1/30s interval", ScenePlayer.frameInterval(forTargetFPS: 30) == 1.0 / 30.0)
Check.that("a 0fps (paused / occluded) directive drives no loop", ScenePlayer.frameInterval(forTargetFPS: 0) == nil)

Check.summarize()

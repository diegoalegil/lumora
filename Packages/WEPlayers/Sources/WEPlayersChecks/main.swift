// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of WEPlayers headless logic (CLT-only equivalent of unit
// tests). The AVKit/AppKit rendering path is validated by running LumoraApp.
import Foundation
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
Check.that("scene is not playable (no scene player yet)", !PlayableWallpapers.isPlayable(resolved(.scene, "s", file: "scene.pkg")))

Check.section("PlayableWallpapers.all / active")
let library = [
    resolved(.scene, "s", file: "scene.pkg"),     // excluded (no scene player)
    resolved(.video, "vweb", file: "a.webm"),     // playable via WebKit fallback
    resolved(.web, "web1", file: "index.html"),
    resolved(.video, "vmp4", file: "b.mp4"),
]
let playable = PlayableWallpapers.all(in: library)
Check.that("all keeps only playable, in order", playable.map(\.ref.id) == ["vweb", "web1", "vmp4"])
Check.that("active picks first playable when no selection",
           PlayableWallpapers.active(in: library, selectedID: nil)?.ref.id == "vweb")
Check.that("active honours a valid selection",
           PlayableWallpapers.active(in: library, selectedID: "vmp4")?.ref.id == "vmp4")
Check.that("active honours a webm (fallback) selection",
           PlayableWallpapers.active(in: library, selectedID: "vweb")?.ref.id == "vweb")
Check.that("active falls back when selection is unplayable (scene)",
           PlayableWallpapers.active(in: library, selectedID: "s")?.ref.id == "vweb")
Check.that("active falls back when selection is unknown",
           PlayableWallpapers.active(in: library, selectedID: "nope")?.ref.id == "vweb")
Check.that("active is nil when nothing is playable",
           PlayableWallpapers.active(in: [resolved(.scene, "s", file: "scene.pkg")], selectedID: nil) == nil)

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

Check.section("Players")
Check.that("VideoPlayer handles the video type", VideoPlayer.supportedType == .video)
Check.that("VideoFallbackPlayer handles the video type", VideoFallbackPlayer.supportedType == .video)
Check.that("WebPlayer handles the web type", WebPlayer.supportedType == .web)

Check.summarize()

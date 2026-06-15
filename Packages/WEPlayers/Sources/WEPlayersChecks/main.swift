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
Check.that("m4v is native", VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.m4v")))
Check.that("uppercase extension is native", VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/A.MP4")))
Check.that("webm is not native", !VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.webm")))
Check.that("mkv is not native", !VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a.mkv")))
Check.that("no extension is not native", !VideoFormatSupport.isNativelyPlayable(URL(fileURLWithPath: "/x/a")))

Check.section("PlayableWallpapers.isPlayable")
Check.that("mp4 video is playable", PlayableWallpapers.isPlayable(resolved(.video, "v", file: "a.mp4")))
Check.that("webm video is not playable", !PlayableWallpapers.isPlayable(resolved(.video, "v", file: "a.webm")))
Check.that("web is playable", PlayableWallpapers.isPlayable(resolved(.web, "w", file: "index.html")))
Check.that("scene is not playable (no scene player yet)", !PlayableWallpapers.isPlayable(resolved(.scene, "s", file: "scene.pkg")))

Check.section("PlayableWallpapers.all / active")
let library = [
    resolved(.scene, "s", file: "scene.pkg"),     // excluded
    resolved(.video, "vweb", file: "a.webm"),     // excluded (codec)
    resolved(.web, "web1", file: "index.html"),
    resolved(.video, "vmp4", file: "b.mp4"),
]
let playable = PlayableWallpapers.all(in: library)
Check.that("all keeps only playable, in order", playable.map(\.ref.id) == ["web1", "vmp4"])
Check.that("active picks first playable when no selection",
           PlayableWallpapers.active(in: library, selectedID: nil)?.ref.id == "web1")
Check.that("active honours a valid selection",
           PlayableWallpapers.active(in: library, selectedID: "vmp4")?.ref.id == "vmp4")
Check.that("active falls back when selection is unplayable",
           PlayableWallpapers.active(in: library, selectedID: "vweb")?.ref.id == "web1")
Check.that("active falls back when selection is unknown",
           PlayableWallpapers.active(in: library, selectedID: "nope")?.ref.id == "web1")
Check.that("active is nil when nothing is playable",
           PlayableWallpapers.active(in: [resolved(.scene, "s", file: "scene.pkg")], selectedID: nil) == nil)

Check.section("Players")
Check.that("VideoPlayer handles the video type", VideoPlayer.supportedType == .video)
Check.that("WebPlayer handles the web type", WebPlayer.supportedType == .web)

Check.summarize()

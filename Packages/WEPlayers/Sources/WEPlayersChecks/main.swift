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

Check.section("VideoWallpaperSelector")
let mixed = [resolved(.web, "w"), resolved(.video, "v1"), resolved(.scene, "s"), resolved(.video, "v2")]
Check.that("picks the first playable video", VideoWallpaperSelector.firstPlayable(in: mixed)?.ref.id == "v1")
Check.that("skips a webm video for a later mp4 one",
           VideoWallpaperSelector.firstPlayable(in: [
               resolved(.video, "vweb", file: "a.webm"),
               resolved(.video, "vmp4", file: "b.mp4"),
           ])?.ref.id == "vmp4")
Check.that("nil when the only video is webm",
           VideoWallpaperSelector.firstPlayable(in: [resolved(.video, "vweb", file: "a.webm")]) == nil)
Check.that("nil when no video present",
           VideoWallpaperSelector.firstPlayable(in: [resolved(.web, "w"), resolved(.scene, "s")]) == nil)
Check.that("nil for empty list", VideoWallpaperSelector.firstPlayable(in: []) == nil)

Check.section("VideoPlayer")
Check.that("handles the video type", VideoPlayer.supportedType == .video)

Check.summarize()

// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of WEPlayers headless logic (CLT-only equivalent of unit
// tests). The AVKit/AppKit rendering path is validated by running LumoraApp.
import Foundation
import WECore
import WEPlayers

func resolved(_ type: WallpaperType, _ name: String) -> ResolvedWallpaper {
    let folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    let manifest = ProjectManifest(title: name, rawType: type.rawValue, file: "main")
    let ref = WallpaperRef(folderURL: folder, manifest: manifest)
    return ResolvedWallpaper(
        ref: ref,
        type: type,
        manifest: manifest,
        mainFileURL: folder.appendingPathComponent("main")
    )
}

Check.section("VideoWallpaperSelector")
let mixed = [resolved(.web, "w"), resolved(.video, "v1"), resolved(.scene, "s"), resolved(.video, "v2")]
Check.that("picks the first video", VideoWallpaperSelector.firstPlayable(in: mixed)?.ref.id == "v1")
Check.that("nil when no video present",
           VideoWallpaperSelector.firstPlayable(in: [resolved(.web, "w"), resolved(.scene, "s")]) == nil)
Check.that("nil for empty list", VideoWallpaperSelector.firstPlayable(in: []) == nil)

Check.section("VideoPlayer")
Check.that("handles the video type", VideoPlayer.supportedType == .video)

Check.summarize()

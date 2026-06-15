// SPDX-License-Identifier: MIT
// Provenance: clean-room. Pure selection logic, kept out of the AppKit-bound renderer so it can be
// verified headlessly: which resolved wallpaper the video player should take.
import WECore

public enum VideoWallpaperSelector {
    /// The first video wallpaper the video player can actually play (a `.video` whose file is in a
    /// format AVFoundation decodes natively), or `nil` if there is none. Videos in formats we can't
    /// decode yet (e.g. `.webm`) are skipped rather than producing a black screen.
    public static func firstPlayable(in wallpapers: [ResolvedWallpaper]) -> ResolvedWallpaper? {
        wallpapers.first { $0.type == .video && VideoFormatSupport.isNativelyPlayable($0.mainFileURL) }
    }
}

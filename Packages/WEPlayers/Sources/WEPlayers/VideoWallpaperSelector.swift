// SPDX-License-Identifier: MIT
// Provenance: clean-room. Pure selection logic, kept out of the AppKit-bound renderer so it can be
// verified headlessly: which resolved wallpaper the video player should take.
import WECore

public enum VideoWallpaperSelector {
    /// The first video wallpaper in a resolved list, or `nil` if none are videos.
    public static func firstPlayable(in wallpapers: [ResolvedWallpaper]) -> ResolvedWallpaper? {
        wallpapers.first { $0.type == .video }
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. Pure selection logic for web wallpapers, kept out of the WebKit-bound
// renderer so it can be verified headlessly.
import WECore

public enum WebWallpaperSelector {
    /// The first web wallpaper in a resolved list, or `nil` if none are web.
    public static func firstPlayable(in wallpapers: [ResolvedWallpaper]) -> ResolvedWallpaper? {
        wallpapers.first { $0.type == .web }
    }
}

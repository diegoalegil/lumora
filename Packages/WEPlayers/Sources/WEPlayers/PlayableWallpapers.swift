// SPDX-License-Identifier: MIT
// Provenance: clean-room. The single place that knows which wallpapers the app can currently play
// (a video the system can decode, or any web page) and resolves the active one from a saved choice.
import WECore

public enum PlayableWallpapers {
    /// Whether the app currently has a working player for this wallpaper.
    public static func isPlayable(_ wallpaper: ResolvedWallpaper) -> Bool {
        switch wallpaper.type {
        case .video: return VideoFormatSupport.isPlayable(wallpaper.mainFileURL)
        case .web:   return true
        case .scene: return false   // no scene player yet
        }
    }

    /// The playable wallpapers, preserving input order.
    public static func all(in wallpapers: [ResolvedWallpaper]) -> [ResolvedWallpaper] {
        wallpapers.filter(isPlayable)
    }

    /// The wallpaper to play: the saved choice if it is still playable, otherwise the first playable
    /// one, otherwise `nil` (the caller falls back).
    public static func active(in wallpapers: [ResolvedWallpaper], selectedID: String?) -> ResolvedWallpaper? {
        let playable = all(in: wallpapers)
        if let selectedID, let chosen = playable.first(where: { $0.ref.id == selectedID }) {
            return chosen
        }
        return playable.first
    }
}

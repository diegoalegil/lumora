// SPDX-License-Identifier: MIT
// Provenance: clean-room. App-wide preferences as a plain Codable value — the settings UI binds to an
// observable wrapper, the store persists this, and the app re-applies it live.
import Foundation

/// User preferences that aren't tied to a single playlist. Plain value type so it round-trips and diffs
/// cleanly; the live-apply (Dock icon, login item) is the host's job.
public struct Preferences: Codable, Sendable, Equatable {
    /// Show the app's Dock icon (`.regular`) instead of running menu-bar-only (`.accessory`).
    public var showDockIcon: Bool
    /// Launch Lumora automatically at login.
    public var launchAtLogin: Bool
    /// Rotate through the selected playlist instead of showing a single fixed wallpaper. Read at launch.
    public var playlistPlayback: Bool
    /// The id of the playlist to play on launch, if any (resolved against the library at startup).
    public var activePlaylistID: UUID?

    public init(showDockIcon: Bool = false, launchAtLogin: Bool = false,
                playlistPlayback: Bool = false, activePlaylistID: UUID? = nil) {
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.playlistPlayback = playlistPlayback
        self.activePlaylistID = activePlaylistID
    }

    // Tolerant decoding: a Preferences value written by an OLDER build (without a key added later) decodes with
    // that field's default instead of failing — otherwise adding any preference would silently reset all of
    // them. The encoder stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playlistPlayback = try c.decodeIfPresent(Bool.self, forKey: .playlistPlayback) ?? false
        activePlaylistID = try c.decodeIfPresent(UUID.self, forKey: .activePlaylistID)
    }
}

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
    /// Target frame rate while a wallpaper is visible on AC power. Applied at launch.
    public var activeFPS: Int
    /// Target frame rate while throttled (on battery, Low Power Mode, or thermal pressure). Applied at launch.
    public var batteryFPS: Int
    /// The ids of wallpapers the user has starred as favorites.
    public var favorites: Set<String>
    /// Let audio-reactive wallpapers sample the system audio so their visualisers move. OFF by default: this
    /// needs the system "Screen Recording" permission (macOS gates SCStream audio under it), and a wallpaper
    /// app shouldn't demand that to show a wallpaper. Off, those scenes simply render their bars flat — exactly
    /// as if the permission were denied — and Lumora never triggers the prompt. The user opts in if they want it.
    public var audioReactive: Bool

    public init(showDockIcon: Bool = true, launchAtLogin: Bool = false,
                playlistPlayback: Bool = false, activePlaylistID: UUID? = nil,
                activeFPS: Int = 60, batteryFPS: Int = 30, favorites: Set<String> = [],
                audioReactive: Bool = false) {
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.playlistPlayback = playlistPlayback
        self.activePlaylistID = activePlaylistID
        self.activeFPS = activeFPS
        self.batteryFPS = batteryFPS
        self.favorites = favorites
        self.audioReactive = audioReactive
    }

    /// What the app should present at launch. On the very FIRST launch we make Lumora discoverable — force the
    /// Dock icon on and open the Library — so a new user finds the real UI. On every later launch we honor the
    /// saved `showDockIcon` and don't reopen the window, so a menu-bar-only choice survives a relaunch instead
    /// of being overridden each time.
    public struct LaunchPresentation: Equatable, Sendable {
        public var showsDockIcon: Bool
        public var opensLibrary: Bool
        public init(showsDockIcon: Bool, opensLibrary: Bool) {
            self.showsDockIcon = showsDockIcon
            self.opensLibrary = opensLibrary
        }
    }

    public static func launchPresentation(isFirstLaunch: Bool, showDockIcon: Bool) -> LaunchPresentation {
        isFirstLaunch
            ? LaunchPresentation(showsDockIcon: true, opensLibrary: true)
            : LaunchPresentation(showsDockIcon: showDockIcon, opensLibrary: false)
    }

    // Tolerant decoding: a Preferences value written by an OLDER build (without a key added later) decodes with
    // that field's default instead of failing — otherwise adding any preference would silently reset all of
    // them. The encoder stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playlistPlayback = try c.decodeIfPresent(Bool.self, forKey: .playlistPlayback) ?? false
        activePlaylistID = try c.decodeIfPresent(UUID.self, forKey: .activePlaylistID)
        activeFPS = try c.decodeIfPresent(Int.self, forKey: .activeFPS) ?? 60
        batteryFPS = try c.decodeIfPresent(Int.self, forKey: .batteryFPS) ?? 30
        favorites = try c.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
        audioReactive = try c.decodeIfPresent(Bool.self, forKey: .audioReactive) ?? false
    }
}

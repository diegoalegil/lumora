// SPDX-License-Identifier: MIT
// Provenance: clean-room. App-wide preferences as a plain Codable value — the settings UI binds to an
// observable wrapper, the store persists this, and the app re-applies it live.
import Foundation

/// User-selectable render quality. Drives the frame rate; effects and full native-Retina resolution stay ON in
/// every tier — the difference is pacing, never disabling features or dropping sharpness (the owner asked that
/// even the lowest tier not look worse, so Ahorro is a pure frame-rate drop).
public enum RenderQuality: String, Codable, Sendable, CaseIterable, Equatable {
    case maximum     // Máxima      — 120 fps (ProMotion), full native Retina, everything on
    case balanced    // Equilibrada — 60 fps, full native Retina
    case powerSaver  // Ahorro      — 30 fps, full native Retina (only the cadence drops)

    public var params: RenderQualityParams {
        switch self {
        case .maximum:    return RenderQualityParams(activeFPS: 120, batteryFPS: 60, renderScaleCap: 1.0)
        case .balanced:   return RenderQualityParams(activeFPS: 60,  batteryFPS: 30, renderScaleCap: 1.0)
        case .powerSaver: return RenderQualityParams(activeFPS: 30,  batteryFPS: 20, renderScaleCap: 1.0)
        }
    }
}

/// The concrete render parameters a `RenderQuality` maps to. A pure value type so the mapping is unit-testable.
public struct RenderQualityParams: Sendable, Equatable {
    /// Target fps while visible on AC power.
    public var activeFPS: Int
    /// Target fps while throttled (battery / Low Power Mode / thermal pressure).
    public var batteryFPS: Int
    /// Multiplier on the display backing scale when sizing the RENDER texture. 1.0 = full native Retina; the
    /// on-screen layer always uses the true backing scale, so a value below 1.0 renders fewer pixels and lets
    /// the layer upscale them. Kept at 1.0 in every tier so no tier ever looks soft.
    public var renderScaleCap: Double

    public init(activeFPS: Int, batteryFPS: Int, renderScaleCap: Double) {
        self.activeFPS = activeFPS
        self.batteryFPS = batteryFPS
        self.renderScaleCap = renderScaleCap
    }
}

/// User preferences that aren't tied to a single playlist. Plain value type so it round-trips and diffs
/// cleanly; the live-apply (Dock icon, login item) is the host's job.
public struct Preferences: Codable, Sendable, Equatable {
    /// The render-quality tier the user picked. Drives frame rate (and, were it ever <1, render scale).
    public var renderQuality: RenderQuality
    /// Show the app's Dock icon (`.regular`) instead of running menu-bar-only (`.accessory`).
    public var showDockIcon: Bool
    /// Launch Lumora automatically at login.
    public var launchAtLogin: Bool
    /// Rotate through the selected playlist instead of showing a single fixed wallpaper. Read at launch.
    public var playlistPlayback: Bool
    /// The id of the playlist to play on launch, if any (resolved against the library at startup).
    public var activePlaylistID: UUID?
    /// The ids of wallpapers the user has starred as favorites.
    public var favorites: Set<String>

    public init(showDockIcon: Bool = true, launchAtLogin: Bool = false,
                playlistPlayback: Bool = false, activePlaylistID: UUID? = nil,
                favorites: Set<String> = [], renderQuality: RenderQuality = .maximum) {
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.playlistPlayback = playlistPlayback
        self.activePlaylistID = activePlaylistID
        self.favorites = favorites
        self.renderQuality = renderQuality
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
        favorites = try c.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
        renderQuality = try c.decodeIfPresent(RenderQuality.self, forKey: .renderQuality) ?? .maximum
    }
}

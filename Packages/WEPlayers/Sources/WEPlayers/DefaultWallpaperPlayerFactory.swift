// SPDX-License-Identifier: MIT
// Provenance: clean-room. The App's concrete WallpaperPlayerFactory: maps a resolved wallpaper to the
// player that renders it. The type→player decision is pure (PlayerKind), so it's unit-checked without
// constructing AVFoundation/WebKit/Metal objects; makeRenderer is the thin construction glue. Loading
// and degrade-on-failure are the caller's job (RendererSurface), so this never touches disk.
import WECore

/// Which concrete player renders a wallpaper. Pure result of the type→player decision.
public enum PlayerKind: Equatable, Sendable {
    /// AVFoundation, for containers macOS decodes natively (mp4/mov…).
    case nativeVideo
    /// A WebKit `<video>` page, for containers AVFoundation can't open (webm/mkv…).
    case fallbackVideo
    /// WebKit, for HTML/JS wallpapers.
    case web
    /// The WEScene Metal compositor.
    case scene
}

/// Builds the right `WallpaperRenderer` for a resolved wallpaper. The only choice it makes is the
/// type→player routing; everything else (loading, lifecycle) belongs to the renderer and its host.
@MainActor
public struct DefaultWallpaperPlayerFactory: WallpaperPlayerFactory {
    public init() {}

    /// The player kind for a wallpaper — pure, so it's testable without building a player. A `.video`
    /// wallpaper routes to native AVFoundation when its container is natively decodable, else to the
    /// WebKit `<video>` fallback.
    public static func kind(for wallpaper: ResolvedWallpaper) -> PlayerKind {
        switch wallpaper.type {
        case .video:
            return VideoFormatSupport.isNativelyPlayable(wallpaper.mainFileURL) ? .nativeVideo : .fallbackVideo
        case .web:
            return .web
        case .scene:
            return .scene
        }
    }

    /// The player kind once a previous native-decode attempt has failed. A `.video` container AVFoundation
    /// accepted by extension but then couldn't decode re-routes to the WebKit `<video>` fallback, which may
    /// handle a codec AVFoundation rejected; every other case is unchanged. Pure, so the re-route is testable.
    public static func kind(for wallpaper: ResolvedWallpaper, decodeFailed: Bool) -> PlayerKind {
        let base = kind(for: wallpaper)
        return (base == .nativeVideo && decodeFailed) ? .fallbackVideo : base
    }

    public func makeRenderer(for wallpaper: ResolvedWallpaper) throws -> any WallpaperRenderer {
        switch Self.kind(for: wallpaper) {
        case .nativeVideo:   return VideoPlayer()
        case .fallbackVideo: return VideoFallbackPlayer()
        case .web:           return WebPlayer()
        case .scene:         return ScenePlayer()
        }
    }
}

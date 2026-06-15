// SPDX-License-Identifier: MIT
// Provenance: clean-room. Which video containers play natively (AVFoundation) vs need the WebKit
// `<video>` fallback (WE ships many VP8/VP9 `.webm` files AVFoundation can't decode), so the app can
// route each to the right player by extension.
import Foundation

public enum VideoFormatSupport {
    /// Container extensions AVFoundation decodes natively on macOS (use `VideoPlayer`).
    public static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Containers AVFoundation can't open but WebKit's `<video>` may (use `VideoFallbackPlayer`).
    public static let fallbackExtensions: Set<String> = ["webm", "mkv", "ogv", "ogg"]

    /// Whether AVFoundation plays this file natively, judged by its container extension.
    public static func isNativelyPlayable(_ url: URL) -> Bool {
        nativeExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file should go through the WebKit `<video>` fallback.
    public static func isFallbackPlayable(_ url: URL) -> Bool {
        fallbackExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the app can show this video at all (natively or via the fallback).
    public static func isPlayable(_ url: URL) -> Bool {
        isNativelyPlayable(url) || isFallbackPlayable(url)
    }
}

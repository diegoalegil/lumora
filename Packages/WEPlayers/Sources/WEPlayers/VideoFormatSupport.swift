// SPDX-License-Identifier: MIT
// Provenance: clean-room. Which video containers AVFoundation can actually decode on macOS, so the
// selector can skip the ones it can't (notably WE's many VP8/VP9 `.webm` files) instead of leaving
// a black wallpaper.
import Foundation

public enum VideoFormatSupport {
    /// Container extensions AVFoundation decodes natively on macOS.
    public static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Whether AVFoundation can likely play this file, judged by its container extension.
    ///
    /// This is a deliberate heuristic: WE ships many `.webm` (VP8/VP9) videos that AVFoundation
    /// cannot decode. Those need a transcode (ffmpeg, Direct build) or an `<video>` fallback, handled
    /// elsewhere — until then we skip them rather than show a black screen.
    public static func isNativelyPlayable(_ url: URL) -> Bool {
        nativeExtensions.contains(url.pathExtension.lowercased())
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (ImageIO / CGImageSource). Loads a wallpaper's bundled preview image
// as a static fallback for any player whose live content can't be shown — a scene whose artwork can't render,
// or a video whose codec AVFoundation/WebKit can't decode — so the surface shows the thumbnail, not black.
import Foundation
import CoreGraphics
import ImageIO

public enum WallpaperPreview {
    /// The preview-image candidates that sit beside a wallpaper's main file, in priority order. Pure (no disk
    /// access), so the resolution — which folder, which filenames — is unit-testable without a real bundle.
    public static func candidateURLs(besides mainFileURL: URL) -> [URL] {
        let folder = mainFileURL.deletingLastPathComponent()
        return ["preview.jpg", "preview.png", "preview.gif", "preview.jpeg"].map { folder.appendingPathComponent($0) }
    }

    /// The wallpaper's bundled `preview.{jpg,png,gif,jpeg}` (a gif decodes to its first frame) sitting beside
    /// its main file, or nil if none decodes. Best-effort: a wallpaper without a preview simply has no fallback
    /// artwork and the surface stays as it was.
    public static func image(besides mainFileURL: URL) -> CGImage? {
        for url in candidateURLs(besides: mainFileURL) {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return nil
    }
}

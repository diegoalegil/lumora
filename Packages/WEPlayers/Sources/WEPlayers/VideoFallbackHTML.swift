// SPDX-License-Identifier: MIT
// Provenance: clean-room. Builds the tiny full-screen <video> page used to play codecs AVFoundation
// can't decode (e.g. VP8/VP9 .webm) through WebKit's media stack instead of leaving a black screen.
import Foundation

public enum VideoFallbackHTML {
    /// A reasonable `<video>` MIME type for a file, by container extension.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "webm":        return "video/webm"
        case "mkv":         return "video/x-matroska"
        case "mp4", "m4v":  return "video/mp4"
        case "mov":         return "video/quicktime"
        case "ogv", "ogg":  return "video/ogg"
        default:            return "application/octet-stream"
        }
    }

    /// A full-screen, cover-fit, looping, muted `<video>` page sourcing `srcURL`.
    public static func page(srcURL: String, mimeType: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
        video { width: 100%; height: 100%; object-fit: cover; display: block; }
        </style>
        </head>
        <body>
        <video autoplay loop muted playsinline>
        <source src="\(srcURL)" type="\(mimeType)">
        </video>
        </body>
        </html>
        """
    }
}

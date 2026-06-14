// SPDX-License-Identifier: MIT
// Provenance: clean-room. Semantics of project.json `type` from docs.wallpaperengine.io.
import Foundation

/// The wallpaper kinds Lumora supports. `application` (a Windows .exe) is intentionally
/// out of scope and rejected at parse time.
///
/// Deliberately NOT `Codable`: the only sanctioned way to obtain one from a manifest is
/// `WallpaperType.parse(_:)`, which rejects `application`. A synthesized `Decodable` would be a
/// second decode path that bypasses that scope check.
public enum WallpaperType: String, Sendable, CaseIterable {
    case scene
    case video
    case web
}

public enum WallpaperTypeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `"type": "application"` — a native Windows executable wallpaper. Not portable.
    case unsupportedApplication
    /// Any unrecognized `type` value.
    case unknown(String)

    public var description: String {
        switch self {
        case .unsupportedApplication:
            return "Wallpaper type 'application' is a Windows executable and is out of scope."
        case .unknown(let raw):
            return "Unknown wallpaper type '\(raw)'."
        }
    }
}

public extension WallpaperType {
    /// Parse a raw `project.json` `type` string, explicitly rejecting `application`.
    static func parse(_ raw: String) throws -> WallpaperType {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scene": return .scene
        case "video": return .video
        case "web": return .web
        case "application": throw WallpaperTypeError.unsupportedApplication
        default: throw WallpaperTypeError.unknown(raw)
        }
    }
}

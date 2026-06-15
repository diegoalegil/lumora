// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. A one-line, human-readable summary of a library scan, for launch logging
// so discovery is observable on a real machine without a debugger.
import Foundation
import WECore

public enum LibrarySummary {
    /// e.g. "4 wallpapers (2 video, 1 web, 1 scene), 6 skipped" or "0 wallpapers".
    public static func line(for result: LibraryScanResult) -> String {
        let counts: [(label: String, n: Int)] = [
            ("video", result.wallpapers.filter { $0.type == .video }.count),
            ("web",   result.wallpapers.filter { $0.type == .web }.count),
            ("scene", result.wallpapers.filter { $0.type == .scene }.count),
        ]
        let breakdown = counts.filter { $0.n > 0 }.map { "\($0.n) \($0.label)" }.joined(separator: ", ")

        let count = result.wallpapers.count
        var line = "\(count) \(count == 1 ? "wallpaper" : "wallpapers")"
        if !breakdown.isEmpty { line += " (\(breakdown))" }
        if !result.rejected.isEmpty { line += ", \(result.rejected.count) skipped" }
        return line
    }
}

// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Why a folder was rejected, kept as data so the UI can show it and the
// checks can assert it — a broken wallpaper must never crash discovery.
import Foundation
import WECore

/// A folder that could not be turned into a playable wallpaper, with the reason why.
public struct ImportDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    public let folderURL: URL
    public let reason: Reason

    public init(folderURL: URL, reason: Reason) {
        self.folderURL = folderURL
        self.reason = reason
    }

    /// The concrete reason a folder was skipped.
    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        /// No `project.json` in the folder.
        case missingProjectJSON
        /// `project.json` exists but could not be read from disk.
        case unreadableProjectJSON(String)
        /// `project.json` is not valid JSON or is missing required fields (e.g. `type`).
        case corruptManifest(String)
        /// `"type": "application"` — a Windows executable wallpaper, out of scope.
        case unsupportedApplication
        /// An unrecognized `type` value.
        case unknownType(String)
        /// The manifest declares no main `file`.
        case missingMainFile
        /// The manifest names a main `file` that is not present on disk.
        case missingMainAsset(String)
        /// The manifest names a main `file` that resolves outside its own folder (path traversal).
        case unsafeMainFile(String)

        public var description: String {
            switch self {
            case .missingProjectJSON:           return "no project.json"
            case .unreadableProjectJSON(let m): return "unreadable project.json: \(m)"
            case .corruptManifest(let m):       return "invalid project.json: \(m)"
            case .unsupportedApplication:       return "unsupported type 'application'"
            case .unknownType(let t):           return "unknown type '\(t)'"
            case .missingMainFile:              return "manifest has no main file"
            case .missingMainAsset(let f):      return "main file '\(f)' is missing on disk"
            case .unsafeMainFile(let f):        return "main file '\(f)' escapes the wallpaper folder"
            }
        }
    }

    public var description: String { "\(folderURL.lastPathComponent): \(reason)" }
}

/// The outcome of scanning a set of folders: the wallpapers that resolved, and the ones that did
/// not (each with a diagnostic). Both lists preserve the order folders were scanned in.
public struct LibraryScanResult: Sendable, Equatable {
    public let wallpapers: [ResolvedWallpaper]
    public let rejected: [ImportDiagnostic]

    public init(wallpapers: [ResolvedWallpaper], rejected: [ImportDiagnostic]) {
        self.wallpapers = wallpapers
        self.rejected = rejected
    }
}

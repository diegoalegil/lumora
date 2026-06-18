// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Bridges on-disk wallpaper folders to WECore.WallpaperRouter, turning a
// folder into either a ResolvedWallpaper or a precise ImportDiagnostic — never a crash.
import Foundation
import WECore

/// Turns wallpaper folders on disk into resolved, ready-to-play descriptors, rejecting anything the
/// app can't handle (unsupported type, broken manifest, missing asset) with a diagnostic instead of
/// failing the whole scan.
public struct WallpaperLibraryScanner: Sendable {
    public let router: WallpaperRouter

    public init(router: WallpaperRouter = WallpaperRouter()) {
        self.router = router
    }

    /// Resolve a single wallpaper folder, or explain why it can't be played.
    public func scan(folderURL: URL) -> Result<ResolvedWallpaper, ImportDiagnostic> {
        func reject(_ reason: ImportDiagnostic.Reason) -> Result<ResolvedWallpaper, ImportDiagnostic> {
            .failure(ImportDiagnostic(folderURL: folderURL, reason: reason))
        }

        let projectURL = folderURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            return reject(.missingProjectJSON)
        }

        let data: Data
        do {
            data = try Data(contentsOf: projectURL)
        } catch {
            return reject(.unreadableProjectJSON(error.localizedDescription))
        }

        let manifest: ProjectManifest
        do {
            manifest = try ProjectManifest.decode(from: data)
        } catch {
            return reject(.corruptManifest(Self.message(for: error)))
        }

        let ref = WallpaperRef(folderURL: folderURL, manifest: manifest)
        do {
            var resolved = try router.resolve(ref: ref, manifest: manifest)
            // A scene wallpaper's manifest names its unpacked source (`scene.json`), but ScenePlayer reads the
            // packaged `scene.pkg` (a PKGV container). PREFER scene.pkg whenever it exists — not only when the
            // loose scene.json is absent: an extracted folder shipping BOTH would otherwise resolve to the
            // loose scene.json, which ScenePlayer can't read as PKGV, marking the scene playable then failing
            // to a fallback fill. Workshop content (pkg only) is unaffected.
            if resolved.type == .scene {
                let packaged = folderURL.appendingPathComponent("scene.pkg")
                if FileManager.default.fileExists(atPath: packaged.path) {
                    resolved = ResolvedWallpaper(ref: ref, type: .scene, manifest: manifest, mainFileURL: packaged)
                }
            }
            guard FileManager.default.fileExists(atPath: resolved.mainFileURL.path) else {
                return reject(.missingMainAsset(manifest.file))
            }
            return .success(resolved)
        } catch {
            return reject(Self.reason(for: error))
        }
    }

    /// Scan many folders, bucketing each into the resolved or rejected list (order preserved).
    public func scan(folders: [URL]) -> LibraryScanResult {
        var wallpapers: [ResolvedWallpaper] = []
        var rejected: [ImportDiagnostic] = []
        for folder in folders {
            switch scan(folderURL: folder) {
            case .success(let wallpaper): wallpapers.append(wallpaper)
            case .failure(let diagnostic): rejected.append(diagnostic)
            }
        }
        return LibraryScanResult(wallpapers: wallpapers, rejected: rejected)
    }

    /// Discover workshop folders via `locator` and scan them all.
    public func scanLibrary(using locator: SteamLibraryLocator) -> LibraryScanResult {
        scan(folders: locator.workshopItemFolders())
    }

    /// Map a routing/parse failure from `WallpaperRouter` to the diagnostic reason to surface.
    private static func reason(for error: Error) -> ImportDiagnostic.Reason {
        if let typeError = error as? WallpaperTypeError {
            switch typeError {
            case .unsupportedApplication: return .unsupportedApplication
            case .unknown(let raw):       return .unknownType(raw)
            }
        }
        if let routing = error as? RoutingError {
            switch routing {
            case .missingMainFile:        return .missingMainFile
            case .unsafeMainFile(let f):  return .unsafeMainFile(f)
            }
        }
        return .corruptManifest(message(for: error))
    }

    /// A compact, human-readable message for a manifest error (the raw description is verbose).
    private static func message(for error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return context.debugDescription
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "\(decoding)"
        }
    }
}

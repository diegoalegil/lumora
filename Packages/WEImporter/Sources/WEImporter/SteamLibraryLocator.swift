// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Steam Workshop on-disk layout (libraryfolders.vdf, then
// steamapps/workshop/content/<appid>/<id>/) per public Steam documentation. No network/steamcmd.
import Foundation

/// Finds the Wallpaper Engine workshop item folders the user already has on disk by reading Steam's
/// `libraryfolders.vdf`. The search roots are injectable so tests can point at a synthetic tree;
/// the default is the standard macOS Steam location. This type only ever *reads* — it never
/// downloads, scrapes, or shells out to steamcmd.
public struct SteamLibraryLocator: Sendable {
    /// Steam app id for Wallpaper Engine; its workshop content lives under this id.
    public static let workshopAppID = "431960"

    /// Roots to search. Each is a Steam installation directory (the folder that contains
    /// `steamapps/`). Injectable for testing.
    public let steamRoots: [URL]

    public init(steamRoots: [URL]? = nil) {
        self.steamRoots = steamRoots ?? SteamLibraryLocator.defaultSteamRoots()
    }

    /// The standard macOS Steam location: `~/Library/Application Support/Steam`.
    public static func defaultSteamRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)]
    }

    /// All Steam library base folders: the ones declared in `libraryfolders.vdf` across every steam
    /// root, plus the roots themselves. Deduplicated by standardized path. Never throws — a missing
    /// or malformed `.vdf` simply degrades to the steam roots.
    public func libraryRoots() -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted { roots.append(standardized) }
        }
        for steamRoot in steamRoots {
            add(steamRoot)
            for path in libraryPaths(inSteamRoot: steamRoot) {
                add(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        return roots
    }

    /// Every Wallpaper Engine workshop item folder across all libraries:
    /// `<library>/steamapps/workshop/content/431960/<id>/`, in a stable (name-sorted) order.
    public func workshopItemFolders() -> [URL] {
        var folders: [URL] = []
        for library in libraryRoots() {
            let contentDir = library
                .appendingPathComponent("steamapps/workshop/content", isDirectory: true)
                .appendingPathComponent(SteamLibraryLocator.workshopAppID, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: contentDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let dirs = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            folders.append(contentsOf: dirs.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return folders
    }

    // MARK: - VDF parsing

    /// Library paths declared in a steam root's `libraryfolders.vdf`, supporting both the current
    /// layout (numbered entries are objects with a `path`) and the legacy one (numbered entries are
    /// the path strings directly). Non-numbered metadata keys are ignored.
    private func libraryPaths(inSteamRoot steamRoot: URL) -> [String] {
        guard let url = libraryFoldersVDF(inSteamRoot: steamRoot),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? KeyValuesParser.parse(text),
              let libraryFolders = root.first("libraryfolders") else {
            return []
        }
        var paths: [String] = []
        for entry in libraryFolders.children {
            if let path = entry.value.first("path")?.stringValue {
                paths.append(path)
            } else if Int(entry.key) != nil, let path = entry.value.stringValue {
                paths.append(path)
            }
        }
        return paths
    }

    /// `libraryfolders.vdf` lives under `steamapps/` (current Steam) or `config/` (older). First
    /// existing candidate wins.
    private func libraryFoldersVDF(inSteamRoot steamRoot: URL) -> URL? {
        let candidates = [
            steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"),
            steamRoot.appendingPathComponent("config/libraryfolders.vdf"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

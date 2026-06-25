// SPDX-License-Identifier: MIT
// Provenance: clean-room. DEV-ONLY offscreen snapshot mode. With `--snapshot <scene> <libDir> <out.png>`,
// the app renders a named SwiftUI scene to a PNG via ImageRenderer and exits — no desktop windows, no Steam
// scan. This lets the UI be visually verified headlessly (no screen-recording permission needed). It ships
// nothing user-facing: absent the flag, this code never runs.
import AppKit
import SwiftUI
import ImageIO
import WECore
import WallpaperShell

enum SnapshotRunner {
    /// True when launched in snapshot mode.
    static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }

    // Retained for the lifetime of the capture so the window/host aren't deallocated mid-render.
    nonisolated(unsafe) private static var heldWindow: NSWindow?

    /// Schedule the render on the main runloop and exit. We render the real AppKit-backed view hierarchy
    /// (NSHostingView) into a bitmap via `cacheDisplay` — that draws the view itself, so it captures
    /// AppKit-backed SwiftUI controls (split views, scroll views, segmented pickers) that `ImageRenderer`
    /// can't, and it needs no screen-recording permission.
    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 3 else {
            FileHandle.standardError.write(Data("usage: --snapshot <scene> <libDir> <out.png>\n".utf8))
            DispatchQueue.main.async { exit(2) }
            return
        }
        let scene = args[i + 1], libDir = args[i + 2], outPath = args[i + 3]
        // Let app.run() start, build the window, give SwiftUI a beat to lay out + draw, then capture.
        DispatchQueue.main.async { build(scene: scene, libDir: libDir) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { capture(to: outPath); exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("snapshot timed out\n".utf8)); exit(3)
        }
    }

    @MainActor
    private static func build(scene: String, libDir: String) {
        // Force a stable dark appearance so snapshots are deterministic regardless of the host's setting.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let entries = SnapshotLibrary.scan(libDir)
        let thumbs = SnapshotLibrary.preload(entries, limit: 60)
        let store = SnapshotLibrary.sampleStore(entries)

        // Prefer a wallpaper with a rich property schema so the detail/Customize panel is well exercised.
        let rich = entries.first { (SnapshotLibrary.propertiesModel(for: $0)?.editableCount ?? 0) >= 6 }

        let root: AnyView
        let size: CGSize
        switch scene {
        case "library":
            let model = LibraryBrowserModel(entries: entries)
            model.activeWallpaperID = entries.first?.id
            model.selectedID = (rich ?? entries.first)?.id
            // Star the first few visible cells + the selected one so the snapshot shows filled stars.
            model.favorites = Set(model.visibleEntries.prefix(3).map(\.id) + [model.selectedID].compactMap { $0 })
            root = AnyView(LibraryBrowserView(model: model, store: store,
                                              makePropertiesModel: { SnapshotLibrary.propertiesModel(for: $0) },
                                              preloadedThumbnails: thumbs))
            size = CGSize(width: 1120, height: 760)
        case "properties":
            guard let target = rich ?? entries.first, let full = SnapshotLibrary.propertiesModel(for: target) else {
                FileHandle.standardError.write(Data("no wallpaper with properties\n".utf8)); exit(2)
            }
            // Cap the schema so a 200-property wallpaper doesn't blow up the offscreen layout.
            let pm = WallpaperPropertiesModel(wallpaperID: full.wallpaperID,
                                              schema: Array(full.schema.prefix(20)), overrides: [:], onChange: { _ in })
            FileHandle.standardError.write(Data("properties scene: \(full.editableCount) editable of \(full.schema.count)\n".utf8))
            root = AnyView(WallpaperPropertiesView(model: pm)
                .padding(20)
                .frame(width: 400, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
            size = CGSize(width: 400, height: 920)
        case "settings":
            let prefs = PreferencesModel(Preferences(showDockIcon: true, activeFPS: 90, batteryFPS: 24))
            root = AnyView(PreferencesSettingsView(preferences: prefs)
                .frame(width: 560)
                .background(Color(nsColor: .windowBackgroundColor)))
            size = CGSize(width: 560, height: 520)
        default:
            FileHandle.standardError.write(Data("unknown scene '\(scene)'\n".utf8)); exit(2)
        }

        let host = NSHostingController(rootView: root.frame(width: size.width, height: size.height))
        host.view.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.setContentSize(size)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        heldWindow = window
    }

    @MainActor
    private static func capture(to outPath: String) {
        guard let view = heldWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("capture failed: no view\n".utf8)); exit(4)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(4)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("snapshot: wrote \(outPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8)); exit(5)
        }
    }
}

/// Builds `LibraryEntry` values straight from a folder of wallpaper folders, reusing the real manifest parser
/// so snapshots reflect real data.
enum SnapshotLibrary {
    static func scan(_ dir: String) -> [LibraryEntry] {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return folders.compactMap { folder -> LibraryEntry? in
            let projectURL = folder.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectURL),
                  let manifest = try? ProjectManifest.decode(from: data),
                  let type = manifest.type else { return nil }
            let id = manifest.workshopID ?? folder.lastPathComponent
            let title = (manifest.title?.isEmpty == false) ? manifest.title! : folder.lastPathComponent
            return LibraryEntry(id: id, title: title, type: type, tags: manifest.tags,
                                description: manifest.description, thumbnailURL: previewURL(in: folder, manifest: manifest),
                                folderURL: folder)
        }
    }

    private static func previewURL(in folder: URL, manifest: ProjectManifest) -> URL? {
        let fm = FileManager.default
        if let named = manifest.preview, !named.isEmpty {
            let url = folder.appendingPathComponent(named)
            if fm.fileExists(atPath: url.path) { return url }
        }
        for name in ["preview.jpg", "preview.gif", "preview.png", "preview.jpeg"] {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Synchronously downsample the first `limit` previews so the offscreen render shows real artwork.
    static func preload(_ entries: [LibraryEntry], limit: Int) -> [String: NSImage] {
        var map: [String: NSImage] = [:]
        for entry in entries.prefix(limit) {
            guard let url = entry.thumbnailURL, let image = downsample(url, maxPixel: 640) else { continue }
            map[entry.id] = image
        }
        return map
    }

    private static func downsample(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Build a customization model for a wallpaper by re-reading its manifest, for the snapshot panels.
    static func propertiesModel(for entry: LibraryEntry) -> WallpaperPropertiesModel? {
        let pj = entry.folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: pj), let manifest = try? ProjectManifest.decode(from: data) else { return nil }
        let schema = WallpaperProperties.schema(from: manifest.general)
        guard WallpaperProperties.editableCount(schema) > 0 else { return nil }
        return WallpaperPropertiesModel(wallpaperID: entry.id, schema: schema, overrides: [:], onChange: { _ in })
    }

    /// A small in-memory store with a couple of playlists so the "Add to Playlist" menus aren't empty.
    static func sampleStore(_ entries: [LibraryEntry]) -> PlaylistStore {
        let store = PlaylistStore(repository: InMemoryPlaylistRepository())
        let favorites = store.addPlaylist(name: "Favorites")
        store.addPlaylist(name: "Focus")
        for entry in entries.prefix(3) { store.addItem(entry.reference, toPlaylist: favorites.id) }
        return store
    }
}

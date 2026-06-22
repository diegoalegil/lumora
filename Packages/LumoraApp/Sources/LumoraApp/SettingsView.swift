// SPDX-License-Identifier: MIT
// Provenance: clean-room (SwiftUI per Apple docs). The settings window: a NavigationSplitView with a
// sidebar (Library · Playlists · Preferences). The logic it drives — PlaylistStore, PlaylistEditorModel,
// PreferencesModel — is unit-tested in WallpaperShell; this file is the (owner-verified) presentation only.
import SwiftUI
import WECore
import WallpaperShell

/// The three areas of the settings window.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case library = "Library"
    case playlists = "Playlists"
    case preferences = "Preferences"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library:     return "photo.on.rectangle.angled"
        case .playlists:   return "list.and.film"
        case .preferences: return "gearshape"
        }
    }
}

/// The root settings view. Binds to the observable models the app owns.
struct SettingsView: View {
    @Bindable var store: PlaylistStore
    @Bindable var preferences: PreferencesModel
    /// The installed wallpapers offered when building a playlist (injected; empty until the library scan wires in).
    let libraryItems: [WallpaperListItem]

    @State private var section: SettingsSection? = .playlists

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 184, max: 220)
            .navigationTitle("Lumora")
        } detail: {
            switch section ?? .playlists {
            case .library:     LibrarySettingsView(items: libraryItems)
            case .playlists:   PlaylistsSettingsView(store: store, libraryItems: libraryItems)
            case .preferences: PreferencesSettingsView(preferences: preferences)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

/// A lightweight, Codable-free display item for a wallpaper in the library grid (the real thumbnail loads
/// async). Kept in the app layer because it's purely presentational.
struct WallpaperListItem: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnailURL: URL?
    var reference: WallpaperReference { WallpaperReference(id: id) }
}

/// The Preferences pane: a native Form with the Dock-icon and launch-at-login toggles, applied live.
struct PreferencesSettingsView: View {
    @Bindable var preferences: PreferencesModel

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Show Lumora in the Dock", isOn: $preferences.showDockIcon)
                    .help("Off keeps Lumora as a menu-bar-only app.")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Preferences")
    }
}

/// The Library pane: a grid of installed wallpapers (thumbnails). Selecting one is how a playlist gets items.
struct LibrarySettingsView: View {
    let items: [WallpaperListItem]

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No wallpapers found",
                                       systemImage: "photo.on.rectangle.angled",
                                       description: Text("Subscribe to wallpapers in Steam's Wallpaper Engine, or import a folder."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                WallpaperThumbnail(url: item.thumbnailURL)
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(item.title).font(.caption).lineLimit(1)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
    }
}

/// An async-loading thumbnail with a neutral placeholder — never blocks the grid.
struct WallpaperThumbnail: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }
}

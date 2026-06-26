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
    /// Set the desktop wallpaper to the one with this id — wired to the app's single-wallpaper apply path.
    let onApply: (String) -> Void

    /// Open straight to the Library: that's where a user goes to "pick a wallpaper", the app's primary action.
    @State private var section: SettingsSection? = .library

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 184, max: 220)
            .navigationTitle("Lumora")
        } detail: {
            switch section ?? .library {
            case .library:     LibrarySettingsView(items: libraryItems, store: store, onApply: onApply)
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

/// Presentation copy for the render-quality tiers (kept in the app layer — it's purely UI text).
extension RenderQuality {
    var title: String {
        switch self {
        case .maximum:    return "Maximum"
        case .balanced:   return "Balanced"
        case .powerSaver: return "Power Saver"
        }
    }
    var detail: String {
        switch self {
        case .maximum:    return "120 fps on a ProMotion display, at full native resolution — the best your Mac can show. Eases to 60 fps on battery."
        case .balanced:   return "60 fps at full native resolution — smooth and light on power."
        case .powerSaver: return "30 fps at full native resolution — the lightest on the battery, with exactly the same sharpness."
        }
    }
    var symbol: String {
        switch self {
        case .maximum:    return "bolt.fill"
        case .balanced:   return "speedometer"
        case .powerSaver: return "leaf.fill"
        }
    }
}

/// The Preferences pane: a native Form with the render-quality picker plus the Dock-icon, login and playlist
/// toggles, applied live.
struct PreferencesSettingsView: View {
    @Bindable var preferences: PreferencesModel

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Render quality", selection: $preferences.renderQuality) {
                    ForEach(RenderQuality.allCases, id: \.self) { quality in
                        Label(quality.title, systemImage: quality.symbol).tag(quality)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(preferences.renderQuality.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every tier renders at full native Retina resolution — only the frame rate changes, so nothing ever looks softer. Takes effect after you restart Lumora.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Appearance") {
                Toggle("Show Lumora in the Dock", isOn: $preferences.showDockIcon)
                    .help("Off keeps Lumora as a menu-bar-only app.")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }
            Section("Playback") {
                Toggle("Rotate through a playlist", isOn: $preferences.playlistPlayback)
                    .help("Play the selected playlist with timed rotation and transitions instead of a single fixed wallpaper. Takes effect after you restart Lumora.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Preferences")
    }
}

/// The Library pane: a grid of installed wallpapers (thumbnails). Click a wallpaper to set it as the desktop
/// wallpaper; right-click to add it to a playlist instead.
struct LibrarySettingsView: View {
    let items: [WallpaperListItem]
    @Bindable var store: PlaylistStore
    /// Set the desktop wallpaper to the one with this id.
    let onApply: (String) -> Void
    /// The wallpaper the user just clicked, so the grid can show which one was applied (the live desktop is the
    /// real confirmation; this is the in-window echo).
    @State private var appliedID: String?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No wallpapers found",
                                       systemImage: "photo.on.rectangle.angled",
                                       description: Text("Lumora plays the Wallpaper Engine wallpapers Steam has already synced to this Mac. Subscribe to some in Wallpaper Engine and they'll appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            Button {
                                appliedID = item.id
                                onApply(item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        WallpaperThumbnail(url: item.thumbnailURL)
                                            .frame(height: 96)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(Color.accentColor,
                                                                  lineWidth: appliedID == item.id ? 3 : 0))
                                        if appliedID == item.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white, Color.accentColor)
                                                .padding(6)
                                        }
                                    }
                                    Text(item.title).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Click to set as your wallpaper")
                            .contextMenu { addToPlaylistMenu(for: item) }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
    }

    /// The right-click menu: add this wallpaper to an existing playlist, or start a new one from it.
    @ViewBuilder
    private func addToPlaylistMenu(for item: WallpaperListItem) -> some View {
        if !store.library.playlists.isEmpty {
            Menu("Add to Playlist") {
                ForEach(store.library.playlists, id: \.id) { playlist in
                    Button(playlist.name) { store.addItem(item.reference, toPlaylist: playlist.id) }
                }
            }
        }
        Button("New Playlist from This…") {
            let playlist = store.addPlaylist(name: item.title)
            store.addItem(item.reference, toPlaylist: playlist.id)
        }
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

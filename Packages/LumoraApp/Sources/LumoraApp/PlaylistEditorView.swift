// SPDX-License-Identifier: MIT
// Provenance: clean-room (SwiftUI per Apple docs). The Playlists pane: a master list of playlists (drag to
// reorder, swipe to delete) and an editor form for the selected one. The editor binds to PlaylistEditorModel
// (unit-tested in WallpaperShell); this file is presentation, verified visually by the owner.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WECore
import WallpaperShell

/// Master list of playlists plus the editor for the selection.
struct PlaylistsSettingsView: View {
    @Bindable var store: PlaylistStore
    let libraryItems: [WallpaperListItem]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedPlaylistID) {
                    ForEach(store.library.playlists) { playlist in
                        Label(playlist.name.isEmpty ? "Untitled" : playlist.name, systemImage: "film.stack")
                            .tag(playlist.id)
                    }
                    .onMove { store.movePlaylists(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for index in offsets where store.library.playlists.indices.contains(index) {
                            store.remove(id: store.library.playlists[index].id)
                        }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button {
                        store.addPlaylist(name: "New Playlist")
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button(action: importPlaylist) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Import a playlist…")
                    Button(action: exportSelectedPlaylist) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export the selected playlist…")
                    .disabled(store.selectedPlaylist == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240)

            if let selected = store.selectedPlaylist {
                PlaylistEditorView(playlist: selected, libraryItems: libraryItems) { edited in
                    store.update(edited)
                }
                .id(selected.id)   // a fresh editor when the selection changes
            } else {
                ContentUnavailableView("No playlist selected", systemImage: "list.and.film",
                                       description: Text("Select a playlist, or create one."))
            }
        }
        .navigationTitle("Playlists")
    }

    /// Write the selected playlist to a JSON file the user picks (a portable backup / share).
    private func exportSelectedPlaylist() {
        guard let playlist = store.selectedPlaylist, let data = try? PlaylistTransfer.export(playlist) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(playlist.name.isEmpty ? "Playlist" : playlist.name).json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Read a playlist JSON file the user picks and add it (with a fresh id) to the library.
    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url),
           let imported = try? PlaylistTransfer.makeImported(from: data) {
            store.add(imported)
        }
    }
}

/// Edits one playlist. Owns a `PlaylistEditorModel` and forwards every change up to the store via `onChange`.
struct PlaylistEditorView: View {
    @State private var model: PlaylistEditorModel
    let libraryItems: [WallpaperListItem]
    let onChange: (Playlist) -> Void

    init(playlist: Playlist, libraryItems: [WallpaperListItem], onChange: @escaping (Playlist) -> Void) {
        _model = State(initialValue: PlaylistEditorModel(playlist))
        self.libraryItems = libraryItems
        self.onChange = onChange
    }

    private func title(for reference: WallpaperReference) -> String {
        libraryItems.first { $0.id == reference.id }?.title ?? reference.id
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Name", text: $model.name)
            }

            Section("Playback") {
                Picker("Order", selection: $model.mode) {
                    Text("In order").tag(PlaybackMode.inOrder)
                    Text("Shuffle").tag(PlaybackMode.shuffle)
                    Text("Random (no repeats)").tag(PlaybackMode.randomNoImmediateRepeat)
                }
                Toggle("Change automatically", isOn: $model.autoRotates)
                if model.autoRotates {
                    HStack {
                        Text("Every")
                        Slider(value: $model.rotationIntervalMinutes,
                               in: PlaylistEditorModel.minIntervalMinutes ... 120)
                        Text("\(Int(model.rotationIntervalMinutes)) min").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }

            Section("Transition") {
                Picker("Style", selection: $model.transitionKind) {
                    Text("Cut").tag(TransitionKind.none)
                    Text("Cross-fade").tag(TransitionKind.crossfade)
                }
                if model.transitionKind == .crossfade {
                    HStack {
                        Text("Duration")
                        Slider(value: $model.transitionDurationSeconds, in: 0 ... PlaylistEditorModel.maxTransitionSeconds)
                        Text(String(format: "%.1fs", model.transitionDurationSeconds)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }

            Section("Wallpapers (\(model.items.count))") {
                if model.items.isEmpty {
                    Text("Add wallpapers from the Library tab.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.items) { reference in
                        Label(title(for: reference), systemImage: "photo")
                    }
                    .onMove { model.moveItems(fromOffsets: $0, toOffset: $1) }
                    .onDelete { model.removeItems(atOffsets: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.playlist) { _, edited in onChange(edited) }
    }
}

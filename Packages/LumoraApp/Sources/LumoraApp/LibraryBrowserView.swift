// SPDX-License-Identifier: MIT
// Provenance: clean-room (SwiftUI per Apple docs). The dedicated Library browser window: a searchable,
// filterable, sortable grid of installed wallpapers on the left and a detail panel on the right. The state
// (search/filter/sort/selection) is the unit-tested `LibraryBrowserModel`; this file is presentation, plus
// closures the app wires to "set as wallpaper" / "reveal in Finder". Snapshot-verified offscreen.
import SwiftUI
import WECore
import WallpaperShell

/// UI affordances for a wallpaper kind (symbol + short label), kept in the app layer so WECore stays UI-free.
extension WallpaperType {
    var symbolName: String {
        switch self {
        case .scene: return "sparkles"
        case .video: return "film"
        case .web:   return "globe"
        }
    }
    var displayName: String {
        switch self {
        case .scene: return "Scene"
        case .video: return "Video"
        case .web:   return "Web"
        }
    }
}

/// The library browser. Bind to `model` + `store`; inject what "apply"/"reveal" do. `preloadedThumbnails`
/// lets the offscreen snapshot harness inject real preview images (the live app loads them async instead).
struct LibraryBrowserView: View {
    @Bindable var model: LibraryBrowserModel
    @Bindable var store: PlaylistStore
    var onApply: (LibraryEntry) -> Void = { _ in }
    var onReveal: (LibraryEntry) -> Void = { _ in }
    var preloadedThumbnails: [String: NSImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 188), spacing: 18)]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                grid
            }
            .frame(minWidth: 460, idealWidth: 720)
            .background(Color(nsColor: .windowBackgroundColor))

            detail
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    // MARK: Header (search · facet · sort · count)

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search wallpapers", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onChange(of: model.searchText) { model.clampSelectionToVisible() }
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; model.clampSelectionToVisible() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))

            HStack(spacing: 10) {
                FacetBar(selection: $model.typeFilter) { model.clampSelectionToVisible() } count: { facetCount($0) }

                Spacer(minLength: 8)

                Menu {
                    Picker("Sort by", selection: $model.sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } label: {
                    Label("Sort: \(model.sortOrder.label)", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
    }

    /// Per-facet count for the segmented bar.
    private func facetCount(_ facet: LibraryTypeFilter) -> Int {
        switch facet {
        case .all:   return model.entries.count
        case .scene: return model.typeCounts[.scene] ?? 0
        case .video: return model.typeCounts[.video] ?? 0
        case .web:   return model.typeCounts[.web] ?? 0
        }
    }

    // MARK: Grid

    private var grid: some View {
        Group {
            let entries = model.visibleEntries
            if entries.isEmpty {
                ContentUnavailableView("No matches",
                                       systemImage: "rectangle.on.rectangle.slash",
                                       description: Text(model.entries.isEmpty
                                           ? "No wallpapers are installed yet. Subscribe to some in Wallpaper Engine."
                                           : "No wallpapers match your search and filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(entries) { entry in
                            LibraryGridCell(entry: entry,
                                            isSelected: entry.id == model.selectedID,
                                            isActive: entry.id == model.activeWallpaperID,
                                            preloaded: preloadedThumbnails[entry.id])
                                .onTapGesture { model.selectedID = entry.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { onApply(entry) })
                                .contextMenu { cellMenu(entry) }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cellMenu(_ entry: LibraryEntry) -> some View {
        Button("Set as Wallpaper") { onApply(entry) }
        if !store.library.playlists.isEmpty {
            Menu("Add to Playlist") {
                ForEach(store.library.playlists, id: \.id) { playlist in
                    Button(playlist.name.isEmpty ? "Untitled" : playlist.name) {
                        store.addItem(entry.reference, toPlaylist: playlist.id)
                    }
                }
            }
        }
        Button("New Playlist from This…") {
            let playlist = store.addPlaylist(name: entry.title)
            store.addItem(entry.reference, toPlaylist: playlist.id)
        }
        Divider()
        Button("Show in Finder") { onReveal(entry) }
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            if let entry = model.selectedEntry {
                WallpaperDetailPanel(entry: entry,
                                     isActive: entry.id == model.activeWallpaperID,
                                     store: store,
                                     preloaded: preloadedThumbnails[entry.id],
                                     onApply: { onApply(entry) },
                                     onReveal: { onReveal(entry) })
            } else {
                ContentUnavailableView("No wallpaper selected", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Pick a wallpaper to see its details."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }
}

extension LibraryEntry {
    var reference: WallpaperReference { WallpaperReference(id: id) }
}

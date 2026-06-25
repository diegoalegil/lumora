// SPDX-License-Identifier: MIT
// Provenance: clean-room (SwiftUI per Apple docs). The cells and detail panel for the library browser:
// a thumbnail tile with selection/active chrome, and a metadata panel (preview, type badge, tags,
// description, actions). Presentation only.
import SwiftUI
import WECore
import WallpaperShell

/// A preview thumbnail. The live app loads it asynchronously from `url`; the snapshot harness can pass a
/// `preloaded` image so offscreen renders show the real artwork deterministically.
struct WallpaperThumbnailImage: View {
    let url: URL?
    var preloaded: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let preloaded {
                Image(nsImage: preloaded).resizable().aspectRatio(contentMode: .fill)
            } else if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            }
        }
    }
}

/// One wallpaper tile: preview, title, a kind icon, and chrome for selection / "currently playing".
struct LibraryGridCell: View {
    let entry: LibraryEntry
    let isSelected: Bool
    let isActive: Bool
    var preloaded: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WallpaperThumbnailImage(url: entry.thumbnailURL, preloaded: preloaded)
                .aspectRatio(16.0 / 10.0, contentMode: .fill)
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if isActive {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                }

            HStack(spacing: 5) {
                Image(systemName: entry.type.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A custom segmented filter (a row of pill buttons with per-kind counts). Built from solid adaptive fills
/// rather than a material-backed `Picker(.segmented)` so it renders predictably and reads as one control.
struct FacetBar: View {
    @Binding var selection: LibraryTypeFilter
    var onChange: () -> Void
    var count: (LibraryTypeFilter) -> Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LibraryTypeFilter.allCases) { facet in
                let selected = facet == selection
                Button {
                    selection = facet
                    onChange()
                } label: {
                    HStack(spacing: 5) {
                        Text(facet.label)
                        Text("\(count(facet))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(selected ? Color.accentColor.opacity(0.9) : .secondary)
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
    }
}

/// A small pill labelling the wallpaper kind.
struct TypeBadge: View {
    let type: WallpaperType
    var body: some View {
        Label(type.displayName, systemImage: type.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

/// A tag chip.
struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(.secondary)
    }
}

/// The right-hand metadata + actions panel for the selected wallpaper.
struct WallpaperDetailPanel: View {
    let entry: LibraryEntry
    let isActive: Bool
    @Bindable var store: PlaylistStore
    var preloaded: NSImage?
    var onApply: () -> Void
    var onReveal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WallpaperThumbnailImage(url: entry.thumbnailURL, preloaded: preloaded)
                    .aspectRatio(16.0 / 10.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title).font(.title2.bold()).lineLimit(2)
                    HStack(spacing: 8) {
                        TypeBadge(type: entry.type)
                        if isActive {
                            Label("Playing", systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !entry.tags.isEmpty {
                    FlowTags(tags: entry.tags)
                }

                VStack(spacing: 8) {
                    Button(action: onApply) {
                        Label(isActive ? "Currently Playing" : "Set as Wallpaper",
                              systemImage: isActive ? "checkmark" : "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isActive)

                    Menu {
                        if store.library.playlists.isEmpty {
                            Text("No playlists yet")
                        } else {
                            ForEach(store.library.playlists, id: \.id) { playlist in
                                Button(playlist.name.isEmpty ? "Untitled" : playlist.name) {
                                    store.addItem(entry.reference, toPlaylist: playlist.id)
                                }
                            }
                        }
                        Divider()
                        Button("New Playlist from This…") {
                            let playlist = store.addPlaylist(name: entry.title)
                            store.addItem(entry.reference, toPlaylist: playlist.id)
                        }
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.large)

                    Button(action: onReveal) {
                        Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
            .padding(18)
        }
    }
}

/// A simple wrapping row of tag chips (HStack would clip; this wraps to the panel width).
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        // A lightweight wrap: chunk into rows of up to 3 so it never overflows the narrow panel.
        let rows = stride(from: 0, to: tags.count, by: 3).map { Array(tags[$0..<min($0 + 3, tags.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { TagChip(text: $0) }
                }
            }
        }
    }
}

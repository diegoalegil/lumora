// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of playlist export/import and PlaylistStore.add.
import Foundation
import WECore
import WallpaperShell

func runPlaylistTransferChecks() {
    Check.section("PlaylistTransfer")

    let original = Playlist(name: "Focus",
                            items: [WallpaperReference(id: "a"), WallpaperReference(id: "b")],
                            mode: .shuffle, rotationInterval: 300,
                            transition: TransitionSettings(kind: .crossfade, duration: 2))

    guard let data = try? PlaylistTransfer.export(original) else { Check.that("export encodes", false); return }
    Check.that("export encodes", true)
    guard let imported = try? PlaylistTransfer.makeImported(from: data) else { Check.that("import decodes", false); return }
    Check.that("import decodes", true)

    Check.that("import preserves the name", imported.name == "Focus")
    Check.that("import preserves the items", imported.items == original.items)
    Check.that("import preserves mode and rotation", imported.mode == .shuffle && imported.rotationInterval == 300)
    Check.that("import preserves the transition", imported.transition.kind == .crossfade && imported.transition.duration == 2)
    Check.that("import assigns a fresh id", imported.id != original.id)

    // Bad data throws rather than crashing.
    Check.that("import rejects garbage", (try? PlaylistTransfer.makeImported(from: Data("not json".utf8))) == nil)

    Check.section("PlaylistStore.add")

    let store = PlaylistStore(repository: InMemoryPlaylistRepository())
    let added = store.add(imported)
    Check.that("add inserts the playlist", store.library.playlist(id: added.id) != nil)
    Check.that("add selects the imported playlist", store.selectedPlaylistID == added.id)
    Check.that("add preserves the items", store.library.playlist(id: added.id)?.items == original.items)
}

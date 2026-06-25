// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of the library browser's pure search/filter/sort and selection state.
import Foundation
import WECore
import WallpaperShell

private func entry(_ id: String, _ title: String, _ type: WallpaperType, tags: [String] = []) -> LibraryEntry {
    LibraryEntry(id: id, title: title, type: type, tags: tags,
                 folderURL: URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true))
}

func runLibraryBrowserChecks() {
    Check.section("LibraryFiltering")

    let lib = [
        entry("1", "Aurora Sky", .scene, tags: ["nature", "calm"]),
        entry("2", "Neon City", .video, tags: ["city", "cyberpunk"]),
        entry("3", "aurora borealis", .web, tags: ["nature"]),
        entry("4", "Forest", .scene, tags: ["nature", "green"]),
    ]

    // Type facet.
    Check.that("all returns everything", LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .title).count == 4)
    Check.that("scene facet keeps only scenes",
               LibraryFiltering.apply(to: lib, search: "", type: .scene, sort: .title).allSatisfy { $0.type == .scene })
    Check.that("scene facet count is 2", LibraryFiltering.apply(to: lib, search: "", type: .scene, sort: .title).count == 2)
    Check.that("video facet count is 1", LibraryFiltering.apply(to: lib, search: "", type: .video, sort: .title).count == 1)
    Check.that("web facet count is 1", LibraryFiltering.apply(to: lib, search: "", type: .web, sort: .title).count == 1)

    // Search by title — case-insensitive, substring, matches both "Aurora Sky" and "aurora borealis".
    let aurora = LibraryFiltering.apply(to: lib, search: "AURORA", type: .all, sort: .title)
    Check.that("search matches title case-insensitively", aurora.count == 2)
    Check.that("search result is title-sorted (borealis before sky)", aurora.map(\.id) == ["3", "1"])

    // Search by tag.
    let cyber = LibraryFiltering.apply(to: lib, search: "cyberpunk", type: .all, sort: .title)
    Check.that("search matches a tag", cyber.map(\.id) == ["2"])

    // Search + facet combine (nature scenes only).
    let natureScenes = LibraryFiltering.apply(to: lib, search: "nature", type: .scene, sort: .title)
    Check.that("search and facet intersect", Set(natureScenes.map(\.id)) == ["1", "4"])

    // Whitespace-only search is treated as empty.
    Check.that("blank search returns all", LibraryFiltering.apply(to: lib, search: "   ", type: .all, sort: .title).count == 4)

    // No match.
    Check.that("no match returns empty", LibraryFiltering.apply(to: lib, search: "zzz", type: .all, sort: .title).isEmpty)

    // Sort by title is alphabetical and case-insensitive.
    Check.that("title sort orders case-insensitively",
               LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .title).map(\.id) == ["3", "1", "4", "2"])

    // Sort by type groups by kind (scene < video < web), alphabetical within.
    Check.that("type sort groups by kind then title",
               LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .type).map(\.id) == ["1", "4", "2", "3"])

    // Deterministic tie-break on id when titles collide.
    let dup = [entry("b", "Same", .scene), entry("a", "Same", .scene)]
    Check.that("equal titles break ties on id",
               LibraryFiltering.apply(to: dup, search: "", type: .all, sort: .title).map(\.id) == ["a", "b"])

    // Counts.
    let counts = LibraryFiltering.counts(in: lib)
    Check.that("counts per kind are correct", counts[.scene] == 2 && counts[.video] == 1 && counts[.web] == 1)
    Check.that("counts of empty library are empty", LibraryFiltering.counts(in: []).isEmpty)

    Check.section("LibraryBrowserModel")

    let model = LibraryBrowserModel(entries: lib)
    Check.that("model selects the first (title-sorted) entry on init", model.selectedID == "3")
    Check.that("model exposes type counts", model.typeCounts[.scene] == 2)

    // Filtering down to where the selection no longer shows -> selection clamps to first visible.
    model.typeFilter = .video
    model.clampSelectionToVisible()
    Check.that("selection clamps into the filtered set", model.selectedID == "2")
    Check.that("selectedEntry resolves", model.selectedEntry?.title == "Neon City")

    // A filter that matches nothing clears the selection.
    model.searchText = "nothingmatches"
    model.clampSelectionToVisible()
    Check.that("empty filter clears selection", model.selectedID == nil)

    // Replacing the library keeps a still-present selection.
    model.searchText = ""; model.typeFilter = .all
    model.selectedID = "4"
    model.replace(entries: [entry("4", "Forest", .scene), entry("9", "New", .video)])
    Check.that("replace keeps a surviving selection", model.selectedID == "4")

    // Replacing where the selection vanished moves to the first visible (title-sorted: "New" < "Older").
    model.replace(entries: [entry("9", "New", .video), entry("8", "Older", .scene)])
    Check.that("replace re-homes a vanished selection", model.selectedID == "9")

    Check.section("LibraryFiltering favorites")

    Check.that("favoritesOnly keeps only starred",
               Set(LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .title,
                                          favoritesOnly: true, favorites: ["2", "4"]).map(\.id)) == ["2", "4"])
    Check.that("favoritesOnly with empty set is empty",
               LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .title,
                                      favoritesOnly: true, favorites: []).isEmpty)
    Check.that("favorites combine with the type facet",
               LibraryFiltering.apply(to: lib, search: "", type: .scene, sort: .title,
                                      favoritesOnly: true, favorites: ["2", "4"]).map(\.id) == ["4"])
    Check.that("favoritesOnly off ignores the set",
               LibraryFiltering.apply(to: lib, search: "", type: .all, sort: .title,
                                      favoritesOnly: false, favorites: ["2"]).count == 4)

    Check.section("LibraryBrowserModel favorites")

    var publishedFavs: Set<String>? = nil
    let favModel = LibraryBrowserModel(entries: lib)
    favModel.favorites = ["1"]
    favModel.onFavoritesChange = { publishedFavs = $0 }
    Check.that("isFavorite reflects the set", favModel.isFavorite("1") && !favModel.isFavorite("2"))
    favModel.toggleFavorite("2")
    Check.that("toggle stars an unstarred wallpaper", favModel.isFavorite("2"))
    Check.that("toggle publishes the new set", publishedFavs == ["1", "2"])
    favModel.toggleFavorite("1")
    Check.that("toggle unstars a starred wallpaper", !favModel.isFavorite("1") && publishedFavs == ["2"])
    favModel.showFavoritesOnly = true
    Check.that("favorites-only narrows the visible set", favModel.visibleEntries.map(\.id) == ["2"])
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of next/previous wallpaper cycling.
import Foundation
import WallpaperShell

func runWallpaperCycleChecks() {
    Check.section("WallpaperCycle")

    let ids = ["a", "b", "c"]
    Check.that("next advances", WallpaperCycle.next(after: "a", in: ids) == "b")
    Check.that("next wraps at the end", WallpaperCycle.next(after: "c", in: ids) == "a")
    Check.that("previous steps back", WallpaperCycle.previous(before: "b", in: ids) == "a")
    Check.that("previous wraps at the start", WallpaperCycle.previous(before: "a", in: ids) == "c")

    Check.that("next of nil is the first", WallpaperCycle.next(after: nil, in: ids) == "a")
    Check.that("previous of nil is the last", WallpaperCycle.previous(before: nil, in: ids) == "c")
    Check.that("next of an unknown id is the first", WallpaperCycle.next(after: "zzz", in: ids) == "a")
    Check.that("previous of an unknown id is the last", WallpaperCycle.previous(before: "zzz", in: ids) == "c")

    Check.that("next of an empty list is nil", WallpaperCycle.next(after: "a", in: []) == nil)
    Check.that("previous of an empty list is nil", WallpaperCycle.previous(before: "a", in: []) == nil)

    let one = ["solo"]
    Check.that("next of a single-item list stays put", WallpaperCycle.next(after: "solo", in: one) == "solo")
    Check.that("previous of a single-item list stays put", WallpaperCycle.previous(before: "solo", in: one) == "solo")
}

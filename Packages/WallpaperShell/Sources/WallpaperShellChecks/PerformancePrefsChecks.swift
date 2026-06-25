// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of the frame-rate preference clamp and tolerant decode.
import Foundation
import WECore
import WallpaperShell

func runPerformancePrefsChecks() {
    Check.section("PlaybackPolicy.clamped")

    Check.that("active fps clamps up to the floor", PlaybackPolicy.clamped(activeFPS: 1, batteryFPS: 30).activeFPS == 15)
    Check.that("active fps clamps down to the ceiling", PlaybackPolicy.clamped(activeFPS: 999, batteryFPS: 30).activeFPS == 120)
    Check.that("active fps passes a normal value", PlaybackPolicy.clamped(activeFPS: 60, batteryFPS: 30).activeFPS == 60)
    Check.that("battery fps floors at 10", PlaybackPolicy.clamped(activeFPS: 60, batteryFPS: 1).batteryFPS == 10)
    Check.that("battery fps never exceeds the active rate",
               PlaybackPolicy.clamped(activeFPS: 24, batteryFPS: 60).batteryFPS == 24)
    Check.that("a normal battery rate passes", PlaybackPolicy.clamped(activeFPS: 60, batteryFPS: 30).batteryFPS == 30)

    Check.section("Preferences fps decode")

    // An older preferences blob (no fps keys) decodes to the defaults rather than failing.
    let legacy = Data(#"{"showDockIcon":true}"#.utf8)
    let decoded = (try? JSONDecoder().decode(Preferences.self, from: legacy)) ?? Preferences()
    Check.that("missing fps keys default to 60/30", decoded.activeFPS == 60 && decoded.batteryFPS == 30)
    Check.that("other fields still decode", decoded.showDockIcon == true)

    // Round-trip with explicit fps.
    var prefs = Preferences()
    prefs.activeFPS = 90
    prefs.batteryFPS = 24
    let data = try? JSONEncoder().encode(prefs)
    let back = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
    Check.that("fps round-trips", back?.activeFPS == 90 && back?.batteryFPS == 24)
}

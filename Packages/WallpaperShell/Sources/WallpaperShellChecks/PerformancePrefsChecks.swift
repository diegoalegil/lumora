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

    Check.section("Preferences decode")

    // An older preferences blob (missing later-added keys) decodes to the defaults rather than failing.
    let legacy = Data(#"{"showDockIcon":true}"#.utf8)
    let decoded = (try? JSONDecoder().decode(Preferences.self, from: legacy)) ?? Preferences()
    Check.that("a missing render-quality key defaults to maximum", decoded.renderQuality == .maximum)
    Check.that("other fields still decode", decoded.showDockIcon == true)

    Check.section("Preferences launch presentation (F34)")

    // First launch makes the app discoverable regardless of the (default) preference.
    let first = Preferences.launchPresentation(isFirstLaunch: true, showDockIcon: false)
    Check.that("first launch forces the Dock icon", first.showsDockIcon)
    Check.that("first launch opens the Library", first.opensLibrary)

    // A later launch honors the saved Appearance choice and never reopens the Library — a menu-bar-only
    // user keeps menu-bar-only instead of having the Dock icon forced back on every relaunch.
    let menuBarOnly = Preferences.launchPresentation(isFirstLaunch: false, showDockIcon: false)
    Check.that("menu-bar-only survives a relaunch", !menuBarOnly.showsDockIcon)
    Check.that("a relaunch doesn't reopen the Library", !menuBarOnly.opensLibrary)
    let dockUser = Preferences.launchPresentation(isFirstLaunch: false, showDockIcon: true)
    Check.that("a saved Dock-icon choice is honored on relaunch", dockUser.showsDockIcon)
}

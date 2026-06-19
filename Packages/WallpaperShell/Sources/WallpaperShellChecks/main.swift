// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of the PlaybackPolicyEngine state machine.
import Foundation
import CoreGraphics
import WECore
import WallpaperShell

let engine = PlaybackPolicyEngine(policy: PlaybackPolicy(activeFPS: 60, batteryFPS: 30))

Check.section("PlaybackPolicyEngine")

// Nominal: visible, on AC -> render at full rate.
let nominal = engine.directive(for: PlaybackInputs())
Check.that("nominal renders", nominal.renderingEnabled)
Check.that("nominal full fps", nominal.targetFPS == 60)

// Occluded -> paused.
let occluded = engine.directive(for: PlaybackInputs(isOccluded: true))
Check.that("occluded paused", !occluded.renderingEnabled)
Check.that("occluded fps 0", occluded.targetFPS == 0)

// Fullscreen app covering desktop -> paused.
let covered = engine.directive(for: PlaybackInputs(desktopCoveredByFullscreenApp: true))
Check.that("fullscreen-cover paused", !covered.renderingEnabled)

// On battery (visible) -> throttled, still rendering.
let battery = engine.directive(for: PlaybackInputs(onBattery: true))
Check.that("battery still renders", battery.renderingEnabled)
Check.that("battery throttled fps", battery.targetFPS == 30)

// Low power mode -> throttled.
let lowPower = engine.directive(for: PlaybackInputs(lowPowerMode: true))
Check.that("low-power throttled fps", lowPower.targetFPS == 30)

// User paused -> paused regardless of everything else.
let userPaused = engine.directive(for: PlaybackInputs(onBattery: true, userPaused: true))
Check.that("user-paused paused", !userPaused.renderingEnabled)

// Display asleep -> paused.
let asleep = engine.directive(for: PlaybackInputs(displayAsleep: true))
Check.that("display-asleep paused", !asleep.renderingEnabled)

// Screen locked / screensaver running -> paused (nothing is visible).
let locked = engine.directive(for: PlaybackInputs(screenLocked: true))
Check.that("screen-locked paused", !locked.renderingEnabled)
Check.that("screen-locked fps 0", locked.targetFPS == 0)

// Thermal pressure (serious/critical) -> throttled but still rendering (throttle, don't freeze).
let thermal = engine.directive(for: PlaybackInputs(thermallyThrottled: true))
Check.that("thermal still renders", thermal.renderingEnabled)
Check.that("thermal throttled fps", thermal.targetFPS == 30)

// Pause precedence: a "not visible" signal beats a throttle signal.
let lockedAndThermal = engine.directive(for: PlaybackInputs(screenLocked: true, thermallyThrottled: true))
Check.that("lock beats thermal -> paused", !lockedAndThermal.renderingEnabled)

// Pause precedence: an occlusion + battery combo still pauses (no render at battery fps).
let combo = engine.directive(for: PlaybackInputs(isOccluded: true, onBattery: true))
Check.that("occlusion beats battery -> paused", !combo.renderingEnabled)

// PlaybackDirective clamps negative fps to 0.
Check.that("directive clamps negative fps", PlaybackDirective(renderingEnabled: true, targetFPS: -5).targetFPS == 0)

// MARK: DesktopCoverDetector (fullscreen-app / maximized-window cover -> treated as occluded -> paused)
Check.section("DesktopCoverDetector")
let display = CGRect(x: 0, y: 0, width: 2000, height: 1000)
typealias WinRect = DesktopCoverDetector.WindowRect
Check.that("a fullscreen window covers the display",
           DesktopCoverDetector.isCovered(displayFrame: display, windows: [WinRect(layer: 0, bounds: display)]))
Check.that("a maximized window (menu-bar margin) still counts as covered",
           DesktopCoverDetector.isCovered(displayFrame: display,
                                          windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 20, width: 2000, height: 980))]))
Check.that("a half-screen window does not cover",
           !DesktopCoverDetector.isCovered(displayFrame: display,
                                           windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))]))
Check.that("a fullscreen rect on a non-normal layer is ignored (e.g. the wallpaper window itself)",
           !DesktopCoverDetector.isCovered(displayFrame: display, windows: [WinRect(layer: -1, bounds: display)]))
Check.that("no windows means not covered",
           !DesktopCoverDetector.isCovered(displayFrame: display, windows: []))
Check.that("two partial windows do not add up to covered",
           !DesktopCoverDetector.isCovered(displayFrame: display,
                                           windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 2000, height: 400)),
                                                     WinRect(layer: 0, bounds: CGRect(x: 0, y: 600, width: 2000, height: 400))]))

// MARK: PlaybackCoordinator (per-display aggregation, via a mock signal source)
Check.section("PlaybackCoordinator")
let mock = MockSignalSource()
let displays: [CGDirectDisplayID] = [1, 2]
var results: [CGDirectDisplayID: PlaybackDirective] = [:]
let coordinator = PlaybackCoordinator(engine: PlaybackPolicyEngine(), source: mock, displays: { displays })
coordinator.onDirective = { id, directive in results[id] = directive }

mock.base = PlaybackInputs(onBattery: true)  // visible, on battery
mock.occluded = [1]                          // display 1 occluded, display 2 visible
coordinator.start()
Check.that("occluded display 1 paused", results[1]?.renderingEnabled == false)
Check.that("visible display 2 renders", results[2]?.renderingEnabled == true)
Check.that("visible display 2 throttled on battery", results[2]?.targetFPS == 30)

mock.occluded = []                           // un-occlude display 1
mock.fire()
Check.that("display 1 resumes after un-occlude", results[1]?.renderingEnabled == true)

mock.base = PlaybackInputs(userPaused: true) // global user pause
mock.fire()
Check.that("user pause stops display 1", results[1]?.renderingEnabled == false)
Check.that("user pause stops display 2", results[2]?.renderingEnabled == false)

// MARK: PlaylistRepository
Check.section("PlaylistRepository")
do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumora-test-\(UUID().uuidString)")
        .appendingPathComponent("playlists.json")
    let repo = JSONPlaylistRepository(fileURL: tmp)
    Check.that("a missing store loads as an empty library", repo.load().isEmpty)
    var lib = PlaylistLibrary([Playlist(name: "Anime", items: [WallpaperReference(id: "123")], mode: .shuffle, rotationInterval: 600),
                               Playlist(name: "Chill", mode: .inOrder)])
    Check.that("saving the library writes the store", { do { try repo.save(lib); return true } catch { return false } }())
    Check.that("the store round-trips through disk", repo.load() == lib)
    lib.upsert(Playlist(name: "Extra"))
    Check.that("re-saving after an edit succeeds", { do { try repo.save(lib); return true } catch { return false } }())
    Check.that("the edited library reloads with the new playlist", repo.load().count == 3)
    // a corrupt file degrades to empty rather than throwing/crashing
    try? Data("this is not json".utf8).write(to: tmp)
    Check.that("a corrupt store loads as an empty library", repo.load().isEmpty)
    // a bare array of playlists (an older/hand-written shape) is tolerated
    if let bareArray = try? JSONEncoder().encode([Playlist(name: "Legacy")]) { try? bareArray.write(to: tmp) }
    Check.that("a bare playlist array is read as a one-item library", repo.load().count == 1)
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
}
// The store is a versioned envelope and persistence is idempotent (save→load→save is stable).
do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumora-test-\(UUID().uuidString)")
        .appendingPathComponent("playlists.json")
    let repo = JSONPlaylistRepository(fileURL: tmp)
    let lib = PlaylistLibrary([Playlist(name: "M", items: [WallpaperReference(id: "z")])])
    try? repo.save(lib)
    let raw = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    Check.that("the on-disk store carries a version tag (migratable envelope)", raw.contains("\"version\""))
    let reloaded = repo.load()
    try? repo.save(reloaded)
    Check.that("save → load → save → load is stable", repo.load() == lib)
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
}

// MARK: DisplaySwitcher
final class RecordingSurface: WallpaperSurface {
    let reference: WallpaperReference
    var opacity: Double = 1
    var torndown = false
    init(_ reference: WallpaperReference) { self.reference = reference }
    func setOpacity(_ opacity: Double) { self.opacity = opacity }
    func teardown() { torndown = true }
}
final class SurfaceRecorder { var made: [RecordingSurface] = [] }

Check.section("DisplaySwitcher")
do {
    let rec = SurfaceRecorder()
    let switcher = DisplaySwitcher { ref in let s = RecordingSurface(ref); rec.made.append(s); return s }
    let a = WallpaperReference(id: "a"), b = WallpaperReference(id: "b"), c = WallpaperReference(id: "c")
    let fade = TransitionSettings(kind: .crossfade, duration: 2)
    // First wallpaper, nothing to fade from → instant, opaque.
    switcher.apply(a, transition: fade, now: 0)
    Check.that("the first wallpaper mounts instantly at full opacity",
               switcher.currentReference == a && rec.made.count == 1 && rec.made[0].opacity == 1 && !switcher.isTransitioning)
    // Cross-fade to b → both surfaces alive, incoming transparent.
    switcher.apply(b, transition: fade, now: 10)
    Check.that("a cross-fade keeps the outgoing surface alive", rec.made.count == 2 && !rec.made[0].torndown)
    Check.that("the incoming surface starts transparent", rec.made[1].opacity == 0 && switcher.isTransitioning)
    switcher.tick(now: 11)
    Check.that("at the midpoint both surfaces are half faded",
               abs(rec.made[0].opacity - 0.5) < 1e-9 && abs(rec.made[1].opacity - 0.5) < 1e-9)
    switcher.tick(now: 12)
    Check.that("the outgoing surface is torn down at the end", rec.made[0].torndown && !rec.made[1].torndown)
    Check.that("the incoming surface becomes current at full opacity",
               switcher.currentReference == b && rec.made[1].opacity == 1 && !switcher.isTransitioning)
    // Re-applying the current wallpaper makes no new surface.
    switcher.apply(b, transition: fade, now: 20)
    Check.that("re-applying the current wallpaper is a no-op", rec.made.count == 2)
    // A .none transition is an instant cut: the old surface is torn down immediately.
    switcher.apply(c, transition: .init(kind: .none, duration: 2), now: 30)
    Check.that("a .none transition is an instant cut",
               rec.made.count == 3 && rec.made[1].torndown && switcher.currentReference == c && rec.made[2].opacity == 1)
}

// MARK: PlaylistPlaybackController (rotation + transition, end-to-end)
Check.section("PlaylistPlaybackController")
do {
    let rec = SurfaceRecorder()
    let switcher = DisplaySwitcher { ref in let s = RecordingSurface(ref); rec.made.append(s); return s }
    let a = WallpaperReference(id: "a"), b = WallpaperReference(id: "b"), c = WallpaperReference(id: "c")
    let playlist = Playlist(name: "Rotate", items: [a, b, c], mode: .inOrder, rotationInterval: 100,
                            transition: .init(kind: .crossfade, duration: 2))
    let player = PlaylistPlaybackController(playlist: playlist, seed: 1, now: 0, switcher: switcher)
    Check.that("starts on the first item, mounted instantly", player.currentReference == a && rec.made.count == 1 && rec.made[0].opacity == 1)
    player.tick(now: 50)
    Check.that("does not rotate before the interval", player.currentReference == a && rec.made.count == 1)
    player.tick(now: 100)
    Check.that("rotates to the second item and begins a cross-fade",
               player.currentReference == b && rec.made.count == 2 && player.isTransitioning && rec.made[1].opacity == 0)
    player.tick(now: 101)
    Check.that("the cross-fade is half-way at the midpoint", abs(rec.made[0].opacity - 0.5) < 1e-9 && abs(rec.made[1].opacity - 0.5) < 1e-9)
    player.tick(now: 102)
    Check.that("the cross-fade finishes and the first surface is released", rec.made[0].torndown && !player.isTransitioning && rec.made[1].opacity == 1)
    player.tick(now: 200)
    Check.that("rotates again one interval later", player.currentReference == c && rec.made.count == 3 && player.isTransitioning)
    player.tick(now: 202)   // finish the c fade
    // Manual skip jumps immediately and restarts the interval.
    player.next(now: 210)
    Check.that("manual next wraps to the first item", player.currentReference == a && rec.made.count == 4)
    player.tick(now: 260)
    Check.that("the interval restarted from the manual skip (no rotation 50s later)", player.currentReference == a)
}
do {
    // Pause holds the elapsed time; resume rotates only after the carried-over remainder elapses. Uses an
    // instant transition so the assertions are about rotation timing, not fade bookkeeping.
    let rec = SurfaceRecorder()
    let switcher = DisplaySwitcher { ref in let s = RecordingSurface(ref); rec.made.append(s); return s }
    let items = [WallpaperReference(id: "x"), WallpaperReference(id: "y")]
    let player = PlaylistPlaybackController(
        playlist: Playlist(name: "P", items: items, mode: .inOrder, rotationInterval: 100, transition: .init(kind: .none, duration: 0)),
        seed: 1, now: 0, switcher: switcher)
    player.pause(now: 40)            // 40 of the 100s interval elapsed
    player.tick(now: 10_000)         // long gap while paused → no rotation
    Check.that("a paused player does not rotate", player.currentReference == items[0])
    player.resume(now: 10_000)       // 60s of the interval remain
    player.tick(now: 10_050)         // only 50 more → not yet
    Check.that("does not rotate before the carried-over remainder elapses", player.currentReference == items[0])
    player.tick(now: 10_060)         // 60 more → rotates
    Check.that("rotates once the carried-over remainder elapses", player.currentReference == items[1])
}

// MARK: PlaylistEditorModel
Check.section("PlaylistEditorModel")
do {
    let items = [WallpaperReference(id: "a"), WallpaperReference(id: "b"), WallpaperReference(id: "c")]
    let model = PlaylistEditorModel(Playlist(name: "Anime", items: items, mode: .inOrder, rotationInterval: 600,
                                             transition: .init(kind: .crossfade, duration: 1.5)))
    Check.that("reads the name and mode", model.name == "Anime" && model.mode == .inOrder)
    model.name = "Chill"; model.mode = .shuffle
    Check.that("edits the name and mode", model.playlist.name == "Chill" && model.playlist.mode == .shuffle)
    // rotation interval shown in minutes, stored as seconds
    Check.that("reads the interval in minutes", model.rotationIntervalMinutes == 10)
    model.rotationIntervalMinutes = 30
    Check.that("writes the interval back as seconds", model.playlist.rotationInterval == 1800)
    model.rotationIntervalMinutes = 99_999
    Check.that("clamps an over-long interval to 24h", model.playlist.rotationInterval == 1440 * 60)
    model.rotationIntervalMinutes = 0
    Check.that("a zero interval turns auto-rotation off", model.playlist.rotationInterval == nil && model.autoRotates == false)
    model.autoRotates = true
    Check.that("turning auto-rotation on restores the default interval", model.playlist.rotationInterval == PlaylistEditorModel.defaultIntervalSeconds)
    // transition duration clamps to [0, 10]
    model.transitionDurationSeconds = 50
    Check.that("clamps an over-long transition", model.playlist.transition.duration == 10)
    model.transitionDurationSeconds = -2
    Check.that("clamps a negative transition to 0", model.playlist.transition.duration == 0)
    model.transitionKind = .none
    Check.that("edits the transition kind", model.playlist.transition.kind == .none)
    // item editing: no-duplicate add, delete, reorder
    model.addItem(WallpaperReference(id: "a"))
    Check.that("adding a duplicate is ignored", model.items.count == 3)
    model.addItem(WallpaperReference(id: "d"))
    Check.that("adding a new wallpaper appends it", model.items.map(\.id) == ["a", "b", "c", "d"])
    model.removeItems(atOffsets: IndexSet([1]))
    Check.that("removing by offset drops the item", model.items.map(\.id) == ["a", "c", "d"])
    model.moveItems(fromOffsets: IndexSet([0]), toOffset: 3)
    Check.that("reordering moves the item", model.items.map(\.id) == ["c", "d", "a"])
    // monitor target
    model.monitorTarget = .display(uuid: "DISPLAY-1")
    Check.that("edits the monitor target", model.playlist.displayTarget == .display(uuid: "DISPLAY-1"))
}

// MARK: Preferences + PreferencesModel
Check.section("PreferencesModel")
do {
    let prefs = Preferences(showDockIcon: true, launchAtLogin: false, activePlaylistID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB"))
    if let data = try? JSONEncoder().encode(prefs), let back = try? JSONDecoder().decode(Preferences.self, from: data) {
        Check.that("preferences round-trip through JSON", back == prefs)
    } else {
        Check.that("preferences encode/decode", false)
    }
    final class ApplyRecorder { var applied: [Preferences] = [] }
    let rec = ApplyRecorder()
    let model = PreferencesModel(Preferences(), onApply: { rec.applied.append($0) })
    Check.that("starts with the Dock icon hidden (menu-bar only)", model.showDockIcon == false)
    model.showDockIcon = true
    Check.that("toggling the Dock icon applies live", model.showDockIcon == true && rec.applied.last?.showDockIcon == true)
    let countAfterFirst = rec.applied.count
    model.showDockIcon = true   // no-op
    Check.that("a no-op edit does not re-apply", rec.applied.count == countAfterFirst)
    model.launchAtLogin = true
    Check.that("toggling launch-at-login applies live", rec.applied.last?.launchAtLogin == true)
    // set(_:) replaces without re-applying (e.g. after loading from disk)
    model.set(Preferences(showDockIcon: false))
    Check.that("set(_:) replaces without firing apply", model.showDockIcon == false && rec.applied.count == countAfterFirst + 1)
}

// MARK: PlaylistStore (observable app state)
Check.section("PlaylistStore")
do {
    let seed = PlaylistLibrary([Playlist(name: "First"), Playlist(name: "Second")])
    let repo = InMemoryPlaylistRepository(seed)
    let store = PlaylistStore(repository: repo)
    Check.that("loads the library from the repository", store.library.count == 2)
    Check.that("selects the first playlist on launch", store.selectedPlaylist?.name == "First")
    // add → grows, selects the new one, persists
    let added = store.addPlaylist(name: "Third")
    Check.that("adding a playlist grows the library and selects it", store.library.count == 3 && store.selectedPlaylistID == added.id)
    Check.that("the addition is persisted", repo.load().count == 3)
    // edit → replaces + persists
    var edited = added; edited.name = "Third+"
    store.update(edited)
    Check.that("editing replaces the playlist and persists", store.library.playlist(id: added.id)?.name == "Third+" && repo.load().playlist(id: added.id)?.name == "Third+")
    // remove the selected → reselects the first remaining, persists
    store.remove(id: added.id)
    Check.that("removing the selected playlist reselects another", store.library.count == 2 && store.selectedPlaylist?.name == "First")
    Check.that("the removal is persisted", repo.load().count == 2)
    // reorder → persists
    store.movePlaylists(fromOffsets: IndexSet([0]), toOffset: 2)
    Check.that("reordering persists", repo.load().playlists.map(\.name) == ["Second", "First"])
}

// MARK: WallpaperPlaybackCoordinator (whole desktop, per display)
Check.section("WallpaperPlaybackCoordinator")
do {
    final class SwitcherRecorder { var surfaces: [String: [RecordingSurface]] = [:] }
    let rec = SwitcherRecorder()
    let coord = WallpaperPlaybackCoordinator(makeSwitcher: { uuid in
        DisplaySwitcher { ref in let s = RecordingSurface(ref); rec.surfaces[uuid, default: []].append(s); return s }
    }, seed: { 1 })
    let a = WallpaperReference(id: "a"), b = WallpaperReference(id: "b")
    let p1 = Playlist(name: "P1", items: [a], displayTarget: .all)
    let p2 = Playlist(name: "P2", items: [b], displayTarget: .all)
    coord.apply(PlaybackPlan(byDisplay: ["D1": p1, "D2": p1]), now: 0)
    Check.that("a plan starts a controller per display", coord.activeDisplays == ["D1", "D2"])
    Check.that("each display shows its playlist's first item", coord.currentReference(forDisplay: "D1") == a && coord.currentReference(forDisplay: "D2") == a)
    Check.that("each display mounted exactly one surface", rec.surfaces["D1"]?.count == 1 && rec.surfaces["D2"]?.count == 1)
    // switch D2 to a different playlist → D2 restarts, D1 keeps running (no new surface)
    coord.apply(PlaybackPlan(byDisplay: ["D1": p1, "D2": p2]), now: 10)
    Check.that("a switched display shows the new playlist", coord.currentReference(forDisplay: "D2") == b)
    Check.that("an unchanged display is not recreated", rec.surfaces["D1"]?.count == 1)
    Check.that("the switched display mounted a new surface", rec.surfaces["D2"]?.count == 2)
    // empty plan stops everything and tears down surfaces
    coord.apply(PlaybackPlan(), now: 20)
    Check.that("an empty plan stops all displays", coord.activeDisplays.isEmpty)
    Check.that("stopping a display tears down its surface", rec.surfaces["D2"]?.last?.torndown == true)
    // a rotating playlist advances on tick
    let rot = Playlist(name: "Rot", items: [a, b], mode: .inOrder, rotationInterval: 100,
                       transition: .init(kind: .none, duration: 0), displayTarget: .all)
    coord.apply(PlaybackPlan(byDisplay: ["D1": rot]), now: 30)
    Check.that("a restarted display shows the first item", coord.currentReference(forDisplay: "D1") == a)
    coord.tick(now: 130)
    Check.that("tick advances each display's rotation", coord.currentReference(forDisplay: "D1") == b)
}

Check.summarize()

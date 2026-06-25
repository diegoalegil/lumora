// SPDX-License-Identifier: MIT
// Provenance: clean-room. Thin menu-bar shell wiring ScreenManager + PlaybackCoordinator and
// choosing a renderer per display: a looping video or a web wallpaper when one is found on disk,
// else the Phase 0 solid-colour fallback.
import AppKit
import WECore
import WallpaperShell
import WEImporter
import WEPlayers

/// A surface with no window to mount in — used only when a display disconnects between a plan being
/// applied and its switcher asking for a surface. It renders nothing and is torn down like any other.
@MainActor
private final class DetachedSurface: WallpaperSurface {
    let reference: WallpaperReference
    init(_ reference: WallpaperReference) { self.reference = reference }
    func setOpacity(_ opacity: Double) {}
    func apply(_ directive: PlaybackDirective) {}
    func teardown() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var nowPlayingItem: NSMenuItem?

    private let screenManager: ScreenManager
    private var signalSource: SystemSignalSource?
    private var coordinator: PlaybackCoordinator?
    private var renderers: [CGDirectDisplayID: any WallpaperRenderer] = [:]
    private let loginItem = LoginItemService()
    private var isPaused = false

    // FASE 5 — playlist-driven playback. Off by default (the proven single-wallpaper path stays untouched, so
    // the default desktop never regresses); the user opts in with the "Rotate through a playlist" preference
    // (read once at launch — toggling it takes effect on the next launch), or the LUMORA_PLAYLIST_PLAYBACK env
    // var. When on, this coordinator owns every display's content, fed by the selected playlist + its rotation/
    // transition. One path is live per launch, no dual-mounting.
    private let playlistPlaybackEnabled = ProcessInfo.processInfo.environment["LUMORA_PLAYLIST_PLAYBACK"] != nil
        || AppDelegate.loadPreferences().playlistPlayback
    private var playlistCoordinator: WallpaperPlaybackCoordinator?
    private var rotationTimer: Timer?
    private let playerFactory = DefaultWallpaperPlayerFactory()
    private var appliedSelection: Playlist?
    /// The "rotate the whole library" fallback playlist, built once with a stable identity (see refreshPlaylistPlayback).
    private var allWallpapersPlaylist: Playlist?

    // Product layer: the playlist library/store and live-applying preferences behind the settings window.
    private lazy var preferences: PreferencesModel = {
        let model = PreferencesModel(Self.loadPreferences())
        model.onApply = { [weak self] prefs in
            self?.applyPreferences(prefs)
            Self.savePreferences(prefs)
        }
        return model
    }()
    /// The selected playlist is restored from (and persisted back to) `Preferences.activePlaylistID`, so the
    /// chosen playlist survives a relaunch instead of always reverting to the first.
    private lazy var playlistStore: PlaylistStore = {
        PlaylistStore(repository: JSONPlaylistRepository.standard(),
                      initialSelection: preferences.preferences.activePlaylistID,
                      onSelectionChange: { [weak self] id in self?.preferences.activePlaylistID = id })
    }()
    private lazy var settingsController = SettingsWindowController(
        store: playlistStore, preferences: preferences,
        libraryItems: { [weak self] in self?.libraryItems() ?? [] })

    /// The dedicated library browser: a searchable/filterable grid + detail panel. Its model is populated from
    /// the installed library after the scan; the window is created lazily on first open and reused after that.
    private let libraryModel = LibraryBrowserModel(entries: [])
    /// Persisted per-wallpaper property overrides (the "Customize" panel writes here).
    private let propertyStore = WallpaperPropertyStore(repository: JSONWallpaperPropertyRepository.standard())
    private lazy var libraryWindow = LibraryWindowController(
        model: libraryModel, store: playlistStore,
        onApply: { [weak self] entry in self?.applyWallpaper(id: entry.id) },
        onReveal: { entry in NSWorkspace.shared.activateFileViewerSelecting([entry.folderURL]) },
        makePropertiesModel: { [weak self] entry in self?.makePropertiesModel(for: entry) })
    private static let preferencesKey = "LumoraPreferences"

    /// The wallpaper to play, chosen at launch from the installed library (nil → solid fallback).
    private var activeWallpaper: ResolvedWallpaper?
    /// The playable wallpapers offered in the picker, and the user's saved choice.
    private var playableWallpapers: [ResolvedWallpaper] = []
    private var selectedWallpaperID: String?
    private var wallpaperSubmenu: NSMenu?
    private var testPicker: TestPickerWindowController?   // test-only quick switcher
    private static let selectedWallpaperKey = "LumoraSelectedWallpaperID"
    private static let pausedKey = "LumoraPaused"
    private static let hasLaunchedBeforeKey = "LumoraHasLaunchedBefore"

    override init() {
        // Window factory: build the desktop window + an empty host. Renderers are attached in
        // reconcile() so their lifecycle is centralized.
        screenManager = ScreenManager { screen in
            let window = DesktopWindow(screen: screen, placement: .behindIcons)
            window.contentView = RendererHostView(frame: window.frame)
            return window
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // Restore the saved Dock-icon / login preference (main.swift starts as menu-bar-only by default).
        applyPreferences(preferences.preferences)

        let source = SystemSignalSource(windowForDisplay: { [weak self] id in
            self?.screenManager.windows[id]
        })
        signalSource = source

        let coordinator = PlaybackCoordinator(
            // Honour the user's chosen frame-rate targets (sanitized), read once at launch.
            engine: PlaybackPolicyEngine(policy: PlaybackPolicy.clamped(
                activeFPS: preferences.preferences.activeFPS,
                batteryFPS: preferences.preferences.batteryFPS)),
            source: source,
            displays: { [weak self] in
                guard let self else { return [] }
                return Array(self.screenManager.windows.keys)
            }
        )
        coordinator.onDirective = { [weak self] id, directive in
            guard let self else { return }
            if self.playlistPlaybackEnabled {
                // The policy engine decides per display; route to that display's playlist surface.
                if let uuid = ScreenManager.displayUUID(for: id) {
                    self.playlistCoordinator?.apply(directive, toDisplay: uuid)
                }
            } else {
                self.renderers[id]?.apply(directive)
            }
        }
        self.coordinator = coordinator

        // Stand up playlist-driven playback before windows exist, so reconcile() can apply the first plan.
        if playlistPlaybackEnabled { startPlaylistPlayback() }

        // Restore whether the user left wallpapers paused, before playback starts, so the choice survives a
        // relaunch instead of silently resuming.
        isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        source.userPaused = isPaused

        // Discover the user's installed wallpapers once, before windows are built, so reconcile()
        // can pick a renderer. Disk-only; nothing is downloaded.
        let library = Self.scanLibrary()
        NSLog("Lumora: \(LibrarySummary.line(for: library))")
        playableWallpapers = WallpaperLibrary.presentable(PlayableWallpapers.all(in: library.wallpapers))
        selectedWallpaperID = UserDefaults.standard.string(forKey: Self.selectedWallpaperKey)
        activeWallpaper = PlayableWallpapers.active(in: playableWallpapers, selectedID: selectedWallpaperID)
        rebuildWallpaperMenu()
        // Feed the library browser the installed wallpapers and mark which one is currently playing.
        libraryModel.replace(entries: libraryEntries())
        libraryModel.activeWallpaperID = activeWallpaper?.ref.id
        // Build the "all wallpapers" rotation fallback once, so its identity is stable across reconciles.
        allWallpapersPlaylist = playableWallpapers.isEmpty ? nil
            : Playlist(name: "All Wallpapers", items: playableWallpapers.map { WallpaperReference(id: $0.ref.id) })
        // Restore starred favorites and persist any change back through the preferences store.
        libraryModel.favorites = preferences.preferences.favorites
        libraryModel.onFavoritesChange = { [weak self] favorites in self?.preferences.favorites = favorites }

        screenManager.onChange = { [weak self] in self?.reconcile() }
        coordinator.start()      // begin monitoring (no windows yet)
        screenManager.start()    // build windows -> onChange -> reconcile attaches renderers

        // Make the app discoverable on the FIRST launch only: a menu-bar-only app with no window is easy to
        // miss (it looks like "nothing happened"), so show a Dock icon and open the library window the first
        // time. On every later launch, honor the saved Appearance preference instead — applyPreferences above
        // already set the policy, so a user who chose menu-bar-only keeps it instead of having the Dock icon
        // and library forced back each launch. Menu-bar-only stays available via Settings → Appearance.
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey)
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
        let launch = Preferences.launchPresentation(isFirstLaunch: isFirstLaunch,
                                                    showDockIcon: preferences.preferences.showDockIcon)
        if launch.showsDockIcon { NSApp.setActivationPolicy(.regular) }
        if launch.opensLibrary { openLibrary() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        screenManager.stop()
        rotationTimer?.invalidate()
        rotationTimer = nil
        playlistCoordinator?.teardown()
        playlistCoordinator = nil
        renderers.values.forEach { $0.tearDown() }
        renderers.removeAll()
    }

    /// Keep the renderer set in sync with the live windows, then re-evaluate playback.
    private func reconcile() {
        let liveIDs = Set(screenManager.windows.keys)

        if playlistPlaybackEnabled {
            // The playlist coordinator owns window content; make sure no single-wallpaper renderer lingers,
            // then re-plan against the current set of displays (add/remove of a display restarts only it).
            renderers.values.forEach { $0.tearDown() }
            renderers.removeAll()
            refreshPlaylistPlayback()
        } else {
            for (id, window) in screenManager.windows where renderers[id] == nil {
                guard let host = window.contentView as? RendererHostView else { continue }
                let renderer = makeRenderer()
                host.setContent(renderer.makeHostedView())
                renderers[id] = renderer
            }
            for id in renderers.keys where !liveIDs.contains(id) {
                renderers[id]?.tearDown()
                renderers.removeValue(forKey: id)
            }
        }

        coordinator?.evaluate()
    }

    // MARK: Playlist-driven playback (FASE 5)

    /// Build the playlist coordinator and start the rotation clock. The coordinator's per-display switcher
    /// mounts a renderer-backed surface inside that display's window; tearing the surfaces in/out is the
    /// switcher's job, so the App only feeds it plans and ticks.
    private func startPlaylistPlayback() {
        let factory = playerFactory
        playlistCoordinator = WallpaperPlaybackCoordinator(makeSwitcher: { [weak self] uuid in
            DisplaySwitcher { [weak self] reference in
                guard let self, let host = self.window(forUUID: uuid)?.contentView else {
                    return DetachedSurface(reference)   // no window (display just left): a harmless no-op surface
                }
                return RendererSurface(reference: reference, resolved: self.resolve(reference),
                                       factory: factory, parent: host)
            }
        })

        // A coarse tick is plenty: rotation intervals are seconds-to-minutes and the cross-fade reads the
        // wall clock each step. .common mode keeps it ticking during menu tracking. A block timer with a weak
        // capture avoids the target/selector retain cycle (the RunLoop retains the timer, which would otherwise
        // transitively pin the whole AppDelegate graph).
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotationTick() }   // added to RunLoop.main → fires on the main thread
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    /// Re-plan playback against the live displays and the selected playlist, then remember what we applied so
    /// `rotationTick` can notice a selection change.
    private func refreshPlaylistPlayback() {
        guard let coordinator = playlistCoordinator else { return }
        let connected = screenManager.windows.keys.compactMap { ScreenManager.displayUUID(for: $0) }
        let selection = playlistStore.selectedPlaylist
        // Never leave the desktop blank when playlist playback is on but no playlist is usable yet: fall back to
        // rotating the whole installed library. As soon as the user picks/fills a real playlist, rotationTick
        // notices the selection change and re-plans to it.
        let effective: Playlist?
        if let selection, !selection.items.isEmpty {
            effective = selection
        } else if let fallback = allWallpapersPlaylist {
            // Cached so it keeps a STABLE identity: the plan diff compares whole Playlist values (id included),
            // and rebuilding the fallback with a fresh UUID on every reconcile would make an unrelated screen
            // change look like a new playlist and needlessly restart (flash) every display.
            effective = fallback
        } else {
            effective = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        coordinator.apply(PlaybackPlan(active: effective, connectedDisplays: connected), now: now)
        // A wallpaper-set re-plan resets each display's rotation clock; if the user has playback paused (incl.
        // a paused state restored at launch), freeze the new clock too so rotation doesn't advance while paused.
        if isPaused { coordinator.pause(now: now) }
        appliedSelection = selection
    }

    @objc private func rotationTick() {
        guard let coordinator = playlistCoordinator else { return }
        // Pick up a selection (or playlist edit) made in Settings since the last tick.
        if playlistStore.selectedPlaylist != appliedSelection { refreshPlaylistPlayback() }
        coordinator.tick(now: ProcessInfo.processInfo.systemUptime)
    }

    /// The desktop window currently driving the display with this stable UUID, if it's still connected.
    private func window(forUUID uuid: String) -> DesktopWindow? {
        for (id, window) in screenManager.windows where ScreenManager.displayUUID(for: id) == uuid {
            return window
        }
        return nil
    }

    /// Resolve a playlist item's reference to an installed wallpaper (nil → the surface degrades to empty).
    private func resolve(_ reference: WallpaperReference) -> ResolvedWallpaper? {
        playableWallpapers.first { $0.ref.id == reference.id }
    }

    /// Swap every display's renderer to the current active wallpaper.
    private func reloadRenderers() {
        renderers.values.forEach { $0.tearDown() }
        renderers.removeAll()
        reconcile()
    }

    /// One renderer per display for the active wallpaper, routed to the right player by type, or the
    /// deep-indigo solid-colour fallback when there's nothing playable (or it fails to load).
    private func makeRenderer() -> any WallpaperRenderer {
        if let wallpaper = activeWallpaper {
            let player: (any WallpaperRenderer)?
            switch wallpaper.type {
            case .video:
                // AVFoundation for native containers; WebKit <video> fallback for the rest (webm…).
                player = VideoFormatSupport.isNativelyPlayable(wallpaper.mainFileURL)
                    ? VideoPlayer() : VideoFallbackPlayer()
            case .web:   player = WebPlayer()
            case .scene:
                let scene = ScenePlayer()   // WEScene Metal compositor
                // Apply the viewer's Customize values (colour scheme, sliders, promptbox off, …) to the scene.
                scene.propertyOverrides = propertyStore.overrides(for: wallpaper.ref.id)
                // Only capture system audio (→ Screen Recording prompt) if the user opted into audio-reactivity.
                scene.audioReactive = preferences.preferences.audioReactive
                player = scene
            }
            if let player {
                do {
                    try player.load(wallpaper)
                    return player
                } catch {
                    NSLog("Lumora: failed to load wallpaper '\(wallpaper.ref.id)' (\(error)); using fallback")
                }
            }
        }
        // No playable wallpaper (or it failed to load): stay fully transparent so the user's real macOS
        // desktop shows through, instead of hijacking it with a solid (purple) fill.
        return SolidColorRenderer(color: .clear)
    }


    /// Scan the installed Steam Workshop library (resolved wallpapers plus skip diagnostics). For local
    /// testing, `LUMORA_LIBRARY_DIR` overrides the source with a folder of `<id>/` wallpaper folders (e.g.
    /// an extracted `431960/`), so a dev machine without a Steam install can still drive a live pass.
    private static func scanLibrary() -> LibraryScanResult {
        let scanner = WallpaperLibraryScanner()
        if let override = ProcessInfo.processInfo.environment["LUMORA_LIBRARY_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            let folders = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return scanner.scan(folders: folders)
        }
        return scanner.scanLibrary(using: SteamLibraryLocator())
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: "Lumora") {
            item.button?.image = image
        } else {
            item.button?.title = "L"
        }

        let menu = NSMenu()

        // A non-interactive header showing what's on screen right now.
        let nowPlaying = NSMenuItem(title: "No wallpaper", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)
        nowPlayingItem = nowPlaying
        menu.addItem(.separator())

        let browse = NSMenuItem(title: "Browse Wallpapers…", action: #selector(openLibrary), keyEquivalent: "l")
        browse.target = self
        menu.addItem(browse)

        // Cycle the active wallpaper through the installed library (⌘] / ⌘[).
        let nextItem = NSMenuItem(title: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "]")
        nextItem.target = self
        menu.addItem(nextItem)
        let prevItem = NSMenuItem(title: "Previous Wallpaper", action: #selector(previousWallpaper), keyEquivalent: "[")
        prevItem.target = self
        menu.addItem(prevItem)

        let wallpaperItem = NSMenuItem(title: "Quick Switch", action: nil, keyEquivalent: "")
        wallpaperItem.submenu = NSMenu()
        menu.addItem(wallpaperItem)
        wallpaperSubmenu = wallpaperItem.submenu

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        // The plain test picker is a development aid (driven by LUMORA_LIBRARY_DIR), not part of the shipping
        // UI — only surface it when that override is in use.
        if ProcessInfo.processInfo.environment["LUMORA_LIBRARY_DIR"] != nil {
            let testPickerItem = NSMenuItem(title: "Test Picker…", action: #selector(openTestPicker), keyEquivalent: "")
            testPickerItem.target = self
            menu.addItem(testPickerItem)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause Wallpapers", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginMenuItem = login

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Lumora", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self   // refresh login-item state each time the menu opens
        item.menu = menu
        statusItem = item
        updateMenuState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // SMAppService status can change externally (System Settings > Login Items). Mirror the OS truth back
        // into the source-of-truth preference (without re-applying — the OS already changed) so the Settings
        // toggle and the persisted value never drift from what the system actually does.
        if preferences.launchAtLogin != loginItem.isEnabled {
            var prefs = preferences.preferences
            prefs.launchAtLogin = loginItem.isEnabled
            preferences.set(prefs)
            Self.savePreferences(prefs)
        }
        updateMenuState()
        updateNowPlaying()   // reflect the current (possibly rotating) wallpaper each time the menu opens
    }

    private func updateMenuState() {
        pauseMenuItem?.title = isPaused ? "Resume Wallpapers" : "Pause Wallpapers"
        loginMenuItem?.state = loginItem.isEnabled ? .on : .off
        // macOS can hold the registration pending the user's approval; say so instead of showing a dead toggle.
        loginMenuItem?.title = loginItem.requiresApproval ? "Launch at Login — Approve in Settings" : "Launch at Login"
    }

    /// Populate the Wallpaper submenu from the discovered library, checking the active one.
    private func rebuildWallpaperMenu() {
        updateNowPlaying()
        guard let submenu = wallpaperSubmenu else { return }
        submenu.removeAllItems()

        guard !playableWallpapers.isEmpty else {
            let empty = NSMenuItem(title: "No wallpapers found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            let hint = NSMenuItem(title: "Subscribe to wallpapers in Steam Workshop, then relaunch Lumora",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(hint)
            return
        }

        for wallpaper in playableWallpapers {
            let item = NSMenuItem(title: WallpaperLibrary.displayTitle(wallpaper),
                                  action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = wallpaper.ref.id
            item.state = (wallpaper.ref.id == activeWallpaper?.ref.id) ? .on : .off
            submenu.addItem(item)
        }
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyWallpaper(id: id)
    }

    @objc private func nextWallpaper() {
        // In playlist mode the rotation owns the desktop, so a manual skip advances each display's playlist
        // rather than the (unused) single-wallpaper selection.
        if playlistPlaybackEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            connectedDisplayUUIDs().forEach { playlistCoordinator?.next(display: $0, now: now) }
            updateNowPlaying()
            return
        }
        let ids = playableWallpapers.map { $0.ref.id }
        if let id = WallpaperCycle.next(after: activeWallpaper?.ref.id, in: ids) { applyWallpaper(id: id) }
    }

    @objc private func previousWallpaper() {
        if playlistPlaybackEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            connectedDisplayUUIDs().forEach { playlistCoordinator?.previous(display: $0, now: now) }
            updateNowPlaying()
            return
        }
        let ids = playableWallpapers.map { $0.ref.id }
        if let id = WallpaperCycle.previous(before: activeWallpaper?.ref.id, in: ids) { applyWallpaper(id: id) }
    }

    /// The stable UUIDs of the displays currently driven by a desktop window.
    private func connectedDisplayUUIDs() -> [String] {
        screenManager.windows.keys.compactMap { ScreenManager.displayUUID(for: $0) }
    }

    /// Reflect what's actually on screen in the menu header and the menu-bar tooltip — the rotating playlist
    /// item in playlist mode, otherwise the single active wallpaper.
    private func updateNowPlaying() {
        let title: String?
        if playlistPlaybackEnabled, let coordinator = playlistCoordinator,
           let uuid = connectedDisplayUUIDs().sorted().first,
           let reference = coordinator.currentReference(forDisplay: uuid),
           let wallpaper = playableWallpapers.first(where: { $0.ref.id == reference.id }) {
            title = WallpaperLibrary.displayTitle(wallpaper)
        } else if let wallpaper = activeWallpaper {
            title = WallpaperLibrary.displayTitle(wallpaper)
        } else {
            title = nil
        }
        if let title {
            nowPlayingItem?.title = "Playing: \(title)"
            statusItem?.button?.toolTip = "Lumora — \(title)"
        } else {
            nowPlayingItem?.title = "No wallpaper"
            statusItem?.button?.toolTip = "Lumora"
        }
    }

    /// Switch every display to the wallpaper with `id` and persist the choice. Shared by the menu and the
    /// test picker.
    private func applyWallpaper(id: String) {
        selectedWallpaperID = id
        UserDefaults.standard.set(id, forKey: Self.selectedWallpaperKey)
        activeWallpaper = PlayableWallpapers.active(in: playableWallpapers, selectedID: id)
        reloadRenderers()
        rebuildWallpaperMenu()
        libraryModel.activeWallpaperID = activeWallpaper?.ref.id
    }

    /// TEST-ONLY: open a plain window listing every wallpaper, switching live as the selection moves.
    @objc private func openTestPicker() {
        if testPicker == nil {
            let rows = playableWallpapers.map { "\(WallpaperLibrary.displayTitle($0)) — \($0.type.rawValue)" }
            let current = playableWallpapers.firstIndex { $0.ref.id == activeWallpaper?.ref.id } ?? 0
            testPicker = TestPickerWindowController(rows: rows, current: current) { [weak self] index in
                guard let self, self.playableWallpapers.indices.contains(index) else { return }
                let id = self.playableWallpapers[index].ref.id
                guard id != self.activeWallpaper?.ref.id else { return }   // selecting the active one: no reload
                self.applyWallpaper(id: id)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        testPicker?.showWindow(nil)
        testPicker?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: Self.pausedKey)
        signalSource?.userPaused = isPaused
        coordinator?.evaluate()
        // Pausing stops the renderers via the policy, but the playlist rotation runs off the wall clock, so
        // without this it would keep advancing (and cross-fading) while "paused" and silently skip ahead.
        // Freeze/resume the schedule too; resume carries over the elapsed time so nothing is cut short.
        let now = ProcessInfo.processInfo.systemUptime
        if isPaused { playlistCoordinator?.pause(now: now) } else { playlistCoordinator?.resume(now: now) }
        updateMenuState()
    }

    @objc private func toggleLogin() {
        // One source of truth: the menu writes the same preference the Settings toggle does, so the change is
        // applied (via applyPreferences) and persisted once — no drift between the two toggles.
        preferences.launchAtLogin = !loginItem.isEnabled
        // A fresh registration often lands in "requires approval"; take the user straight to the toggle.
        if loginItem.requiresApproval { loginItem.openSystemSettings() }
        updateMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func openLibrary() {
        libraryWindow.show()
    }

    /// The preview image for a wallpaper: the manifest's named `preview` if it's on disk, else the first of the
    /// common preview file names that exists (WE writes preview.gif as often as preview.jpg), else nil.
    private func previewURL(for wallpaper: ResolvedWallpaper) -> URL? {
        let folder = wallpaper.ref.folderURL
        let fm = FileManager.default
        if let named = wallpaper.manifest.preview, !named.isEmpty {
            let url = folder.appendingPathComponent(named)
            if fm.fileExists(atPath: url.path) { return url }
        }
        for name in ["preview.gif", "preview.jpg", "preview.png", "preview.jpeg"] {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The installed wallpapers as display items for the settings Library grid.
    private func libraryItems() -> [WallpaperListItem] {
        playableWallpapers.map { wallpaper in
            WallpaperListItem(id: wallpaper.ref.id,
                              title: WallpaperLibrary.displayTitle(wallpaper),
                              thumbnailURL: previewURL(for: wallpaper))
        }
    }

    /// The installed wallpapers as rich entries for the dedicated library browser (carries type, tags and
    /// description so the grid can filter/sort and the detail panel can show metadata).
    private func libraryEntries() -> [LibraryEntry] {
        playableWallpapers.map { wallpaper in
            LibraryEntry(id: wallpaper.ref.id,
                         title: WallpaperLibrary.displayTitle(wallpaper),
                         type: wallpaper.type,
                         tags: wallpaper.manifest.tags,
                         description: wallpaper.manifest.description,
                         thumbnailURL: previewURL(for: wallpaper),
                         folderURL: wallpaper.ref.folderURL)
        }
    }

    /// Build a customization model for a wallpaper from its manifest schema and any saved overrides, wiring
    /// edits back to the persistent store. Returns nil when the wallpaper exposes no editable properties.
    private func makePropertiesModel(for entry: LibraryEntry) -> WallpaperPropertiesModel? {
        guard let wallpaper = playableWallpapers.first(where: { $0.ref.id == entry.id }) else { return nil }
        let schema = WallpaperProperties.schema(from: wallpaper.manifest.general)
        guard WallpaperProperties.editableCount(schema) > 0 else { return nil }
        let id = entry.id
        return WallpaperPropertiesModel(wallpaperID: id, schema: schema,
                                        overrides: propertyStore.overrides(for: id),
                                        onChange: { [weak self] in self?.propertyStore.setOverrides($0, for: id) })
    }

    /// Apply preferences live: the Dock icon (regular vs accessory) and the login item. Called on launch (to
    /// restore the saved state) and whenever the settings UI changes them.
    private func applyPreferences(_ prefs: Preferences) {
        // Only flip the Dock policy when it actually changes — applyPreferences runs for every preference edit
        // (including starring a favorite), and re-setting the same activation policy each time is needless churn.
        let desiredPolicy: NSApplication.ActivationPolicy = prefs.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy { NSApp.setActivationPolicy(desiredPolicy) }
        // applyPreferences also runs at every launch; only (un)register the login item when the desired state
        // actually differs from the current registration, instead of churning SMAppService each time.
        if prefs.launchAtLogin != loginItem.isEnabled {
            do {
                try loginItem.setEnabled(prefs.launchAtLogin)
            } catch {
                // Don't modal-alert here. The menu toggle surfaces approval.
                NSLog("Lumora: couldn't change Launch at Login: \(error.localizedDescription)")
            }
        }
        updateMenuState()
    }

    private static func loadPreferences() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    private static func savePreferences(_ prefs: Preferences) {
        if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: preferencesKey) }
    }
}

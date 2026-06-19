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

    private let screenManager: ScreenManager
    private var signalSource: SystemSignalSource?
    private var coordinator: PlaybackCoordinator?
    private var renderers: [CGDirectDisplayID: any WallpaperRenderer] = [:]
    private let loginItem = LoginItemService()
    private var isPaused = false

    // FASE 5 — playlist-driven playback. Env-gated for owner verification: the default path is the proven
    // single-wallpaper one (`renderers`/`makeRenderer`), untouched. When LUMORA_PLAYLIST_PLAYBACK is set,
    // this coordinator instead owns every display's content, fed by the selected playlist + its rotation/
    // transition. One path is live per launch (no dual-mounting), so the default desktop never regresses.
    private let playlistPlaybackEnabled = ProcessInfo.processInfo.environment["LUMORA_PLAYLIST_PLAYBACK"] != nil
    private var playlistCoordinator: WallpaperPlaybackCoordinator?
    private var rotationTimer: Timer?
    private let playerFactory = DefaultWallpaperPlayerFactory()
    private var appliedSelection: Playlist?

    // Product layer: the playlist library/store and live-applying preferences behind the settings window.
    private let playlistStore = PlaylistStore(repository: JSONPlaylistRepository.standard())
    private lazy var preferences: PreferencesModel = {
        let model = PreferencesModel(Self.loadPreferences())
        model.onApply = { [weak self] prefs in
            self?.applyPreferences(prefs)
            Self.savePreferences(prefs)
        }
        return model
    }()
    private lazy var settingsController = SettingsWindowController(
        store: playlistStore, preferences: preferences,
        libraryItems: { [weak self] in self?.libraryItems() ?? [] })
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
            engine: PlaybackPolicyEngine(),
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

        screenManager.onChange = { [weak self] in self?.reconcile() }
        coordinator.start()      // begin monitoring (no windows yet)
        screenManager.start()    // build windows -> onChange -> reconcile attaches renderers

        // Test mode: surface the picker on launch so a live pass doesn't have to hunt for the menu-bar icon.
        if ProcessInfo.processInfo.environment["LUMORA_LIBRARY_DIR"] != nil { openTestPicker() }
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
        // wall clock each step. .common mode keeps it ticking during menu tracking.
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(rotationTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    /// Re-plan playback against the live displays and the selected playlist, then remember what we applied so
    /// `rotationTick` can notice a selection change.
    private func refreshPlaylistPlayback() {
        guard let coordinator = playlistCoordinator else { return }
        let connected = screenManager.windows.keys.compactMap { ScreenManager.displayUUID(for: $0) }
        let selection = playlistStore.selectedPlaylist
        coordinator.apply(PlaybackPlan(active: selection, connectedDisplays: connected),
                          now: ProcessInfo.processInfo.systemUptime)
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
            case .scene: player = ScenePlayer()   // WEScene Metal compositor
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
        // Fallback proof-of-ownership fill so it's obvious Lumora owns the desktop.
        return SolidColorRenderer(color: NSColor(srgbRed: 0.16, green: 0.13, blue: 0.28, alpha: 1))
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

        let wallpaperItem = NSMenuItem(title: "Wallpaper", action: nil, keyEquivalent: "")
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
        // SMAppService status can change externally (System Settings > Login Items).
        updateMenuState()
    }

    private func updateMenuState() {
        pauseMenuItem?.title = isPaused ? "Resume Wallpapers" : "Pause Wallpapers"
        loginMenuItem?.state = loginItem.isEnabled ? .on : .off
        // macOS can hold the registration pending the user's approval; say so instead of showing a dead toggle.
        loginMenuItem?.title = loginItem.requiresApproval ? "Launch at Login — Approve in Settings" : "Launch at Login"
    }

    /// Populate the Wallpaper submenu from the discovered library, checking the active one.
    private func rebuildWallpaperMenu() {
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

    /// Switch every display to the wallpaper with `id` and persist the choice. Shared by the menu and the
    /// test picker.
    private func applyWallpaper(id: String) {
        selectedWallpaperID = id
        UserDefaults.standard.set(id, forKey: Self.selectedWallpaperKey)
        activeWallpaper = PlayableWallpapers.active(in: playableWallpapers, selectedID: id)
        reloadRenderers()
        rebuildWallpaperMenu()
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
        updateMenuState()
    }

    @objc private func toggleLogin() {
        do {
            try loginItem.setEnabled(!loginItem.isEnabled)
            // A fresh registration often lands in "requires approval"; take the user straight to the toggle.
            if loginItem.requiresApproval { loginItem.openSystemSettings() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    /// The installed wallpapers as display items for the settings Library grid.
    private func libraryItems() -> [WallpaperListItem] {
        playableWallpapers.map { wallpaper in
            WallpaperListItem(id: wallpaper.ref.id,
                              title: WallpaperLibrary.displayTitle(wallpaper),
                              thumbnailURL: wallpaper.ref.folderURL.appendingPathComponent("preview.jpg"))
        }
    }

    /// Apply preferences live: the Dock icon (regular vs accessory) and the login item. Called on launch (to
    /// restore the saved state) and whenever the settings UI changes them.
    private func applyPreferences(_ prefs: Preferences) {
        NSApp.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
        try? loginItem.setEnabled(prefs.launchAtLogin)
        loginMenuItem?.state = loginItem.isEnabled ? .on : .off
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

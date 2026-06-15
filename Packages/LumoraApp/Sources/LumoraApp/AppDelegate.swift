// SPDX-License-Identifier: MIT
// Provenance: clean-room. Thin menu-bar shell wiring ScreenManager + PlaybackCoordinator and
// choosing a renderer per display: a looping video or a web wallpaper when one is found on disk,
// else the Phase 0 solid-colour fallback.
import AppKit
import WECore
import WallpaperShell
import WEImporter
import WEPlayers

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

    /// The wallpaper to play, chosen at launch from the installed library (nil → solid fallback).
    private var activeWallpaper: ResolvedWallpaper?
    /// The playable wallpapers offered in the picker, and the user's saved choice.
    private var playableWallpapers: [ResolvedWallpaper] = []
    private var selectedWallpaperID: String?
    private var wallpaperSubmenu: NSMenu?
    private static let selectedWallpaperKey = "LumoraSelectedWallpaperID"

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
            self?.renderers[id]?.apply(directive)
        }
        self.coordinator = coordinator

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        screenManager.stop()
        renderers.values.forEach { $0.tearDown() }
        renderers.removeAll()
    }

    /// Keep the renderer set in sync with the live windows, then re-evaluate playback.
    private func reconcile() {
        let liveIDs = Set(screenManager.windows.keys)

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

        coordinator?.evaluate()
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
            case .scene: player = nil   // no scene player yet
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

    /// Scan the installed Steam Workshop library (resolved wallpapers plus skip diagnostics).
    private static func scanLibrary() -> LibraryScanResult {
        WallpaperLibraryScanner().scanLibrary(using: SteamLibraryLocator())
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
    }

    /// Populate the Wallpaper submenu from the discovered library, checking the active one.
    private func rebuildWallpaperMenu() {
        guard let submenu = wallpaperSubmenu else { return }
        submenu.removeAllItems()

        guard !playableWallpapers.isEmpty else {
            let empty = NSMenuItem(title: "No wallpapers found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
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
        selectedWallpaperID = id
        UserDefaults.standard.set(id, forKey: Self.selectedWallpaperKey)
        activeWallpaper = PlayableWallpapers.active(in: playableWallpapers, selectedID: id)
        reloadRenderers()
        rebuildWallpaperMenu()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        signalSource?.userPaused = isPaused
        coordinator?.evaluate()
        updateMenuState()
    }

    @objc private func toggleLogin() {
        do {
            try loginItem.setEnabled(!loginItem.isEnabled)
        } catch {
            NSLog("Lumora: login item toggle failed: \(error)")
        }
        updateMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

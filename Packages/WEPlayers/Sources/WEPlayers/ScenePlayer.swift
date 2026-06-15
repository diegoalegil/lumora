// SPDX-License-Identifier: MIT
// Provenance: clean-room. Plays a `.scene` wallpaper: reads its scene.pkg, prepares the layer textures
// once with WEScene's compositor, and drives a light animation loop (a gentle camera parallax) into a
// layer-backed view. Scenes without parallax render a single still frame. Apple frameworks only. No GPL.
import AppKit
import WECore
import WEImporter
import WEScene

public enum ScenePlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedType(WallpaperType)

    public var description: String {
        switch self {
        case .unsupportedType(let type): return "ScenePlayer cannot play a '\(type.rawValue)' wallpaper."
        }
    }
}

/// Renders a Wallpaper Engine scene (`.pkg`) to the desktop: its composited layers, with a subtle
/// automatic camera parallax for the layers that have depth.
@MainActor
public final class ScenePlayer: WallpaperRenderer {
    public static let supportedType: WallpaperType = .scene

    private let renderer = SceneRenderer()
    private var hostView: SceneHostView?
    private var package: ScenePackage?
    private var document: RenderableScene?
    private var prepared: PreparedScene?

    private var timer: Timer?
    private var elapsed = 0.0
    private var isPaused = false
    private var loggedRenderFailure = false
    private static let frameInterval = 1.0 / 30.0

    public init() {}

    public func makeHostedView() -> NSView {
        let view = SceneHostView { [weak self] in self?.present() }
        hostView = view
        return view
    }

    public func load(_ wallpaper: ResolvedWallpaper) throws {
        guard wallpaper.type == Self.supportedType else {
            throw ScenePlayerError.unsupportedType(wallpaper.type)
        }
        let data = try Data(contentsOf: wallpaper.mainFileURL)
        let scenePackage = try ScenePackage.read(data)
        package = scenePackage
        document = try SceneGraph.load(from: scenePackage)
        prepared = nil
    }

    public func resume() {
        isPaused = false
        present()
    }

    public func pause() {
        isPaused = true
        stopLoop()   // freeze on the last frame
    }

    public func apply(_ directive: PlaybackDirective) {
        if directive.renderingEnabled { resume() } else { pause() }
    }

    public func tearDown() {
        stopLoop()
        hostView?.removeFromSuperview()
        hostView = nil
        package = nil
        document = nil
        prepared = nil
    }

    // MARK: - Rendering

    private func ensurePrepared() {
        guard prepared == nil, let renderer, let document, let package else { return }
        prepared = renderer.prepare(document, package: package)
    }

    private func startLoopIfAnimated() {
        guard !isPaused, timer == nil, let prepared, prepared.hasParallax else { return }
        let timer = Timer(timeInterval: Self.frameInterval, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        elapsed += Self.frameInterval
        present()
    }

    /// Composite the prepared scene at the view's pixel size and the current time into its layer.
    private func present() {
        guard let hostView, hostView.bounds.width > 1, hostView.bounds.height > 1 else { return }
        ensurePrepared()
        startLoopIfAnimated()

        let scale = hostView.window?.backingScaleFactor ?? 2
        let width = max(1, Int(hostView.bounds.width * scale))
        let height = max(1, Int(hostView.bounds.height * scale))

        if let renderer, let prepared, prepared.layerCount > 0,
           let frame = renderer.render(prepared, width: width, height: height, time: elapsed),
           let image = frame.makeCGImage() {
            hostView.layer?.backgroundColor = nil
            hostView.layer?.contents = image
        } else {
            // No Metal device, decode failure, or nothing visible — show the proof-of-ownership fill
            // instead of a transparent (invisible) layer.
            hostView.layer?.contents = nil
            hostView.layer?.backgroundColor = SceneHostView.fallbackColor
            if !loggedRenderFailure {
                NSLog("Lumora: scene render failed; showing the fallback fill")
                loggedRenderFailure = true
            }
        }
    }
}

/// A layer-backed view that re-composites the scene whenever it is resized or its backing scale
/// changes, so the desktop always shows a crisp, correctly-sized frame.
@MainActor
private final class SceneHostView: NSView {
    /// The deep-indigo proof-of-ownership fill shown when a scene can't be rendered.
    static let fallbackColor = NSColor(srgbRed: 0.16, green: 0.13, blue: 0.28, alpha: 1).cgColor

    private let onResize: () -> Void

    init(onResize: @escaping () -> Void) {
        self.onResize = onResize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize()
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. Plays a `.scene` wallpaper: reads its scene.pkg, prepares the layer textures
// once with WEScene's compositor, and drives a light animation loop (a gentle camera parallax) into a
// layer-backed view. Scenes without parallax render a single still frame. Apple frameworks only. No GPL.
import AppKit
import ImageIO
import WECore
import WEImporter
import WEScene
import WESceneDynamics

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
    private var lastDirective: PlaybackDirective?   // dedup identical directives so a burst of unchanged
                                                    // policy signals doesn't trigger redundant full renders
    // System-audio spectrum for audio-reactive scenes. Capture only starts for a scene that actually uses
    // audio (so non-audio wallpapers never trigger the Screen Recording permission prompt); if permission
    // is denied the engine stays silent and the scene renders flat.
    private let audio = AudioEngine()
    private var sceneUsesAudio = false
    private var loggedRenderFailure = false
    private var previewImage: CGImage?   // the wallpaper's own thumbnail, shown if the scene can't render
    /// The frame rate the playback policy currently wants — 60 active, 30 on battery / low-power, 0 when
    /// paused or occluded. Driven by `apply(_:)`; 60 until a directive says otherwise.
    private var targetFPS = 60

    /// The render-loop tick interval for a target frame rate, or nil when the rate is 0 — a paused or
    /// occluded directive (targetFPS 0) wants no continuous rendering, just the last still frame held.
    nonisolated public static func frameInterval(forTargetFPS fps: Int) -> Double? {
        fps > 0 ? 1.0 / Double(fps) : nil
    }

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
        elapsed = 0.0   // reset the animation clock so a reload (playlist switch, re-apply) starts the new scene at t=0
        sceneUsesAudio = Self.usesAudio(scenePackage)
        previewImage = Self.loadPreview(besides: wallpaper.mainFileURL)
    }

    /// Whether the scene reacts to audio (so we should capture system audio for it). A cheap substring scan,
    /// done once on load, that keeps the Screen Recording permission prompt off wallpapers that don't react to
    /// sound. Two paths react: shaders that read the `g_AudioSpectrum` globals, and JS SceneScript visualisers
    /// (audio-bar clones) that pull the spectrum through the audio-buffer API — the latter live inline in
    /// scene.json or in a `scripts/*.js` file, not in a shader.
    private static func usesAudio(_ package: ScenePackage) -> Bool {
        for entry in package.entries {
            let path = entry.path
            let isShader = path.hasSuffix(".frag") || path.hasSuffix(".vert")
            let isScript = path.hasSuffix(".js") || path == "scene.json"
            // Only shader/script entries can reference audio. Check the suffix BEFORE decoding, so a multi-MB
            // .tex atlas or embedded .mp4 isn't materialised as a UTF-8 string on the load path.
            guard isShader || isScript, let text = String(data: entry.data, encoding: .utf8) else { continue }
            if isShader {
                if text.contains("g_AudioSpectrum") || text.contains("audioprocessing") { return true }
            } else {
                if text.contains("registerAudioBuffers") || text.contains("AUDIO_RESOLUTION") { return true }
            }
        }
        return false
    }

    /// The wallpaper's bundled `preview.{jpg,png,gif}` (gif → first frame) as a static fallback for a
    /// scene whose artwork can't be rendered (e.g. an unsupported animated texture).
    private static func loadPreview(besides sceneURL: URL) -> CGImage? {
        let folder = sceneURL.deletingLastPathComponent()
        for name in ["preview.jpg", "preview.png", "preview.gif", "preview.jpeg"] {
            let url = folder.appendingPathComponent(name)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return nil
    }

    public func resume() {
        isPaused = false
        if sceneUsesAudio { audio.start() }   // no-op if already running or permission unavailable
        present()
    }

    public func pause() {
        isPaused = true
        audio.stop()   // release the audio tap while frozen — no point capturing for a still frame
        stopLoop()     // freeze on the last frame
    }

    public func apply(_ directive: PlaybackDirective) {
        // An unchanged directive leaves the scene exactly as it already is — re-applying it would call
        // resume() → present(), a full synchronous GPU render + readback, for nothing. The policy engine
        // re-emits the resolved directive to every display on any signal change (occlusion/thermal/power),
        // so identical directives arrive in bursts; skip them. (A static scene still renders on view-ready
        // via the host view's resize callback, so dedup can't leave it blank.)
        guard directive != lastDirective else { return }
        lastDirective = directive
        guard directive.renderingEnabled else { pause(); return }
        let rateChanged = directive.targetFPS != targetFPS
        let wasRunning = timer != nil
        targetFPS = directive.targetFPS
        resume()
        // If the loop was already running and the policy changed the rate (e.g. the Mac went on battery),
        // rebuild the timer so the new interval takes effect instead of staying at the previous rate.
        if rateChanged, wasRunning {
            stopLoop()
            startLoopIfAnimated()
        }
    }

    public func tearDown() {
        audio.stop()
        stopLoop()
        hostView?.removeFromSuperview()
        hostView = nil
        package = nil
        document = nil
        prepared = nil
        previewImage = nil
    }

    // MARK: - Rendering

    private func ensurePrepared() {
        guard prepared == nil, let renderer, let document, let package else { return }
        prepared = renderer.prepare(document, package: package)
    }

    private func startLoopIfAnimated() {
        guard !isPaused, timer == nil, let prepared, prepared.hasAnimation,
              let interval = Self.frameInterval(forTargetFPS: targetFPS) else { return }
        // A block timer with a weak self avoids the retain cycle a `target: self` timer creates (the run
        // loop keeps the timer alive, so a strong target would outlive a torn-down player). The block is
        // nonisolated but the timer is added to the main run loop, so it always fires on the main thread —
        // assume the main actor to call `tick()` (instead of an async hop that would lag the frame).
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        elapsed += Self.frameInterval(forTargetFPS: targetFPS) ?? 0
        present()
    }

    /// Composite the prepared scene at the view's pixel size and the current time into its layer.
    private func present() {
        guard let hostView, hostView.bounds.width > 1, hostView.bounds.height > 1 else { return }
        ensurePrepared()
        // A puppet-rigged scene only renders live when every puppet layer assembled into a sane mesh
        // (`puppetReady`). Otherwise drawing its raw layer atlas would show scattered body parts, so fall back
        // to the wallpaper's own static preview — or, if it ships none, the solid fill. Never the scattered
        // geometry: a scene without a preview must not slip through to the live render here.
        if document?.usesPuppet == true, prepared?.puppetReady != true {
            hostView.layer?.contents = previewImage
            hostView.layer?.backgroundColor = previewImage == nil ? SceneHostView.fallbackColor : nil
            return
        }
        startLoopIfAnimated()

        let scale = hostView.window?.backingScaleFactor ?? 2
        let width = max(1, Int(hostView.bounds.width * scale))
        let height = max(1, Int(hostView.bounds.height * scale))

        if let renderer, let prepared, prepared.isRenderable,
           let frame = renderer.render(prepared, width: width, height: height, time: elapsed, audio: audio),
           let image = frame.makeCGImage() {
            hostView.layer?.backgroundColor = nil
            hostView.layer?.contents = image
        } else if let previewImage {
            // The scene has no renderable layers (e.g. an unsupported animated texture) — show the
            // wallpaper's own preview thumbnail rather than an empty fill.
            hostView.layer?.backgroundColor = nil
            hostView.layer?.contents = previewImage
        } else {
            // No Metal device, decode failure, or nothing visible — show the proof-of-ownership fill
            // instead of a transparent (invisible) layer.
            hostView.layer?.contents = nil
            hostView.layer?.backgroundColor = SceneHostView.fallbackColor
            if !loggedRenderFailure {
                NSLog("Lumora: scene render failed; showing the preview/fallback fill")
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

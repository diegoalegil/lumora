// SPDX-License-Identifier: MIT
// Provenance: clean-room. Plays a `.scene` wallpaper: reads its scene.pkg, prepares the layer textures
// once with WEScene's compositor, and drives a light animation loop (a gentle camera parallax) into a
// layer-backed view. Scenes without parallax render a single still frame. Apple frameworks only. No GPL.
import AppKit
import Metal
import QuartzCore
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

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0   // for the real per-frame delta; 0 before the first tick
    private var elapsed = 0.0
    private var isPaused = false
    private var lastDirective: PlaybackDirective?   // dedup identical directives so a burst of unchanged
                                                    // policy signals doesn't trigger redundant full renders
    private var loggedRenderFailure = false
    private var previewImage: CGImage?   // the wallpaper's own thumbnail, shown if the scene can't render
    /// The frame rate the playback policy currently wants — 60 active, 30 on battery / low-power, 0 when
    /// paused or occluded. Driven by `apply(_:)`; 60 until a directive says otherwise.
    private var targetFPS = 60
    /// The viewer's per-property Customize values (a colour scheme, a slider, a visibility toggle), applied to
    /// the scene at load. Set before `load(_:)`; empty renders as authored.
    public var propertyOverrides: [String: PropertyValue] = [:]

    /// The render-loop tick interval for a target frame rate, or nil when the rate is 0 — a paused or
    /// occluded directive (targetFPS 0) wants no continuous rendering, just the last still frame held.
    nonisolated public static func frameInterval(forTargetFPS fps: Int) -> Double? {
        fps > 0 ? 1.0 / Double(fps) : nil
    }

    /// The display-link refresh range for a target frame rate. The quality tier feeds this through the playback
    /// directive (Máxima 120 / Equilibrada 60 / Ahorro 30); the display caps it to its own max (so 120 becomes
    /// 60 on a non-ProMotion panel). Pure, so it's unit-testable.
    nonisolated public static func frameRateRange(forTargetFPS fps: Int) -> CAFrameRateRange {
        let f = Float(max(1, fps))
        return CAFrameRateRange(minimum: f, maximum: f, preferred: f)
    }

    public init() {}

    public func makeHostedView() -> NSView {
        let view = SceneHostView(device: renderer?.device,
                                 pixelFormat: renderer?.compositePixelFormat ?? .rgba8Unorm,
                                 onResize: { [weak self] in self?.present() },
                                 onWindowChange: { [weak self] in self?.viewMovedToWindow() })
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
        document = try SceneGraph.load(from: scenePackage, overrides: propertyOverrides)
        prepared = nil
        elapsed = 0.0   // reset the animation clock so a reload (playlist switch, re-apply) starts the new scene at t=0
        lastTimestamp = 0
        previewImage = WallpaperPreview.image(besides: wallpaper.mainFileURL)
    }

    public func resume() {
        isPaused = false
        present()
    }

    public func pause() {
        isPaused = true
        stopLink()     // freeze on the last frame
    }

    public func apply(_ directive: PlaybackDirective) {
        // An unchanged directive leaves the scene exactly as it already is — re-applying it would re-render for
        // nothing. The policy engine re-emits the resolved directive to every display on any signal change
        // (occlusion/thermal/power), so identical directives arrive in bursts; skip them. (A static scene still
        // renders on view-ready via the host view's resize callback, so dedup can't leave it blank.)
        guard directive != lastDirective else { return }
        lastDirective = directive
        guard directive.renderingEnabled else { pause(); return }
        targetFPS = directive.targetFPS
        // Re-point the display link at the new rate (e.g. the Mac went on battery) — no loop to rebuild.
        displayLink?.preferredFrameRateRange = Self.frameRateRange(forTargetFPS: targetFPS)
        resume()
    }

    public func tearDown() {
        displayLink?.invalidate()
        displayLink = nil
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

    /// (Re)build the display link when the host view gains a window, so it binds to that window's display and
    /// migrates with it across monitors (picking up a 120 Hz ProMotion panel's higher refresh). Torn down when
    /// the view leaves its window.
    private func viewMovedToWindow() {
        displayLink?.invalidate()
        displayLink = nil
        guard let hostView, hostView.window != nil else { return }
        let link = hostView.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = Self.frameRateRange(forTargetFPS: targetFPS)
        link.isPaused = true   // unpaused by startLinkIfAnimated() once there's animation to drive
        link.add(to: .main, forMode: .common)
        displayLink = link
        present()              // draw the first frame as soon as the view is on screen
    }

    /// Start ticking the display link for an animated, visible scene. A still scene (no parallax/keyframes/
    /// effects/particles/script) leaves the link paused and renders a single frame.
    private func startLinkIfAnimated() {
        guard !isPaused, let prepared, prepared.hasAnimation, targetFPS > 0 else { return }
        displayLink?.preferredFrameRateRange = Self.frameRateRange(forTargetFPS: targetFPS)
        displayLink?.isPaused = false
    }

    private func stopLink() {
        displayLink?.isPaused = true
    }

    /// The display-link callback: advance the clock by the REAL time since the last frame (so animation tracks
    /// wall-clock at any refresh rate, and feeds engine.time/frametime), then render. Fires on the main thread.
    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp > 0 ? max(0, now - lastTimestamp) : (Self.frameInterval(forTargetFPS: targetFPS) ?? (1.0 / 60))
        lastTimestamp = now
        elapsed += dt
        present()
    }

    /// Composite the prepared scene at the current time straight into the host's CAMetalLayer drawable — no
    /// per-frame GPU→CPU readback — or fall back to the wallpaper's preview / a transparent fill.
    private func present() {
        guard let hostView, hostView.bounds.width > 1, hostView.bounds.height > 1 else { return }
        ensurePrepared()
        // A puppet-rigged scene only renders live when every puppet layer assembled into a sane mesh
        // (`puppetReady`). Otherwise drawing its raw layer atlas would show scattered body parts, so fall back
        // to the wallpaper's own static preview — or, if it ships none, a transparent fill. Never the scattered
        // geometry: a scene without a preview must not slip through to the live render here.
        if document?.usesPuppet == true, prepared?.puppetReady != true {
            hostView.showFallback(previewImage)
            return
        }
        startLinkIfAnimated()

        // Render into the next drawable at its exact device-pixel size and present it. nextDrawable() is nil
        // when there's no Metal device, the layer has no size yet, or every drawable is in flight — fall back
        // to the preview for that frame rather than risk a mismatch or a blank.
        if let renderer, let prepared, prepared.isRenderable,
           let drawable = hostView.nextDrawable() {
            let width = drawable.texture.width, height = drawable.texture.height
            if width > 0, height > 0 {
                _ = renderer.render(prepared, width: width, height: height, time: elapsed,
                                    into: drawable.texture, present: { $0.present(drawable) })
                hostView.showLive()
                return
            }
        }
        if let previewImage {
            // No renderable layers (e.g. an unsupported animated texture), or no free drawable — show the
            // wallpaper's own preview thumbnail rather than an empty fill.
            hostView.showFallback(previewImage)
        } else {
            // No Metal device, decode failure, or nothing visible — stay transparent so the real desktop shows.
            hostView.showFallback(nil)
            if !loggedRenderFailure {
                NSLog("Lumora: scene render failed; showing the preview/fallback fill")
                loggedRenderFailure = true
            }
        }
    }
}

/// A Metal-backed host view: live frames are presented straight into a CAMetalLayer drawable (no readback),
/// and a sibling layer shows the wallpaper's preview / a transparent fill when the scene can't render. It
/// re-sizes the drawable to the display's device pixels on every resize / backing-scale change.
@MainActor
private final class SceneHostView: NSView {
    /// Shown when a scene can't be rendered and has no preview: stay transparent so the user's real desktop
    /// shows through, rather than hijacking it with a solid fill.
    static let fallbackColor = NSColor.clear.cgColor

    private let metalLayer = CAMetalLayer()
    private let fallbackLayer = CALayer()
    private let onResize: () -> Void
    private let onWindowChange: () -> Void

    init(device: MTLDevice?, pixelFormat: MTLPixelFormat,
         onResize: @escaping () -> Void, onWindowChange: @escaping () -> Void) {
        self.onResize = onResize
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = pixelFormat
        metalLayer.framebufferOnly = true          // we only render into + present it, never read it back
        metalLayer.isOpaque = true                 // a wallpaper fills the screen; opaque composites cheaper
        metalLayer.contentsGravity = .resizeAspectFill
        fallbackLayer.contentsGravity = .resizeAspectFill
        fallbackLayer.isHidden = true
        layer?.addSublayer(metalLayer)
        layer?.addSublayer(fallbackLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Keep both sub-layers filling the view at the display's true device-pixel resolution, so the live frame
    /// maps 1:1 (no upscale → no blur) and the drawable is the right size before any render.
    private func updateLayerGeometry() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        fallbackLayer.frame = bounds
        fallbackLayer.contentsScale = scale
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayerGeometry()
        onResize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerGeometry()
        onResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange()
    }

    /// The next drawable to render into, or nil if the layer has no device/size yet or all drawables are in
    /// flight — the caller then holds the last frame or shows the preview, never crashing.
    func nextDrawable() -> CAMetalDrawable? {
        guard metalLayer.device != nil,
              metalLayer.drawableSize.width >= 1, metalLayer.drawableSize.height >= 1 else { return nil }
        return metalLayer.nextDrawable()
    }

    /// Show the live Metal frame (the drawable just presented).
    func showLive() {
        metalLayer.isHidden = false
        fallbackLayer.isHidden = true
    }

    /// Show the wallpaper's preview image (or a transparent fill when nil) instead of a live frame.
    func showFallback(_ image: CGImage?) {
        metalLayer.isHidden = true
        fallbackLayer.contents = image
        fallbackLayer.backgroundColor = image == nil ? Self.fallbackColor : nil
        fallbackLayer.isHidden = false
    }
}

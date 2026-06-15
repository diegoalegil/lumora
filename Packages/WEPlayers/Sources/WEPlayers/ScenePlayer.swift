// SPDX-License-Identifier: MIT
// Provenance: clean-room. Plays a `.scene` wallpaper by reading its scene.pkg and rendering it with
// WEScene's Metal compositor into a layer-backed view. Static first cut (one composite per size);
// animation and parallax build on top. Apple frameworks only. No GPL.
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

/// Renders a Wallpaper Engine scene (`.pkg`) to the desktop as a still composite of its layers.
@MainActor
public final class ScenePlayer: WallpaperRenderer {
    public static let supportedType: WallpaperType = .scene

    private let renderer = SceneRenderer()
    private var hostView: SceneHostView?
    private var package: ScenePackage?
    private var document: RenderableScene?

    public init() {}

    public func makeHostedView() -> NSView {
        let view = SceneHostView { [weak self] size in self?.renderFrame(size: size) }
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
    }

    public func resume() { hostView.map { renderFrame(size: $0.bounds.size) } }

    public func pause() {}

    public func apply(_ directive: PlaybackDirective) {
        if directive.renderingEnabled { resume() }
    }

    public func tearDown() {
        hostView?.removeFromSuperview()
        hostView = nil
        package = nil
        document = nil
    }

    /// Composite the scene at the view's pixel size and show it. Re-renders only when the size changes.
    private var renderedPixelSize: (Int, Int)?
    private func renderFrame(size: CGSize) {
        guard let renderer, let document, let package, let hostView, size.width > 1, size.height > 1 else { return }
        let scale = hostView.window?.backingScaleFactor ?? 2
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        if renderedPixelSize.map({ $0 == (width, height) }) == true { return }
        guard let frame = renderer.render(document, package: package, width: width, height: height),
              let image = frame.makeCGImage() else { return }
        hostView.layer?.contents = image
        renderedPixelSize = (width, height)
    }
}

/// A layer-backed view that re-renders the scene whenever it is resized to fill the desktop.
@MainActor
private final class SceneHostView: NSView {
    private let onResize: (CGSize) -> Void

    init(onResize: @escaping (CGSize) -> Void) {
        self.onResize = onResize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize(newSize)
    }
}

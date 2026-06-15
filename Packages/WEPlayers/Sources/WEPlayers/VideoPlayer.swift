// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (AVQueuePlayer, AVPlayerLooper, AVPlayerLayer). Loops a
// video wallpaper into the desktop window and honours the shell's PlaybackDirective.
import AVFoundation
import AppKit
import WECore

public enum VideoPlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedType(WallpaperType)

    public var description: String {
        switch self {
        case .unsupportedType(let type):
            return "VideoPlayer cannot play a '\(type.rawValue)' wallpaper."
        }
    }
}

/// Plays a `.video` wallpaper on a gapless loop behind the desktop icons.
@MainActor
public final class VideoPlayer: WallpaperRenderer {
    /// The wallpaper type this renderer handles.
    public static let supportedType: WallpaperType = .video

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var hostView: VideoHostView?

    public init() {
        // A wallpaper is silent by default; audio is a later, opt-in setting.
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    public func makeHostedView() -> NSView {
        let view = VideoHostView(player: player)
        hostView = view
        return view
    }

    public func load(_ wallpaper: ResolvedWallpaper) throws {
        guard wallpaper.type == Self.supportedType else {
            throw VideoPlayerError.unsupportedType(wallpaper.type)
        }
        // AVPlayerLooper drives the queue player for gapless looping of a single item.
        let item = AVPlayerItem(url: wallpaper.mainFileURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    public func resume() { player.play() }

    public func pause() { player.pause() }

    public func apply(_ directive: PlaybackDirective) {
        // Video plays at its native rate; only the on/off decision applies here. The `targetFPS`
        // throttle is meaningful for the Metal scene renderer, not for AVPlayer.
        if directive.renderingEnabled { resume() } else { pause() }
    }

    public func tearDown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        hostView?.removeFromSuperview()
        hostView = nil
    }
}

/// An NSView whose backing layer *is* an AVPlayerLayer, so the video always fills the view bounds
/// without manual frame bookkeeping.
@MainActor
private final class VideoHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { playerLayer }
}

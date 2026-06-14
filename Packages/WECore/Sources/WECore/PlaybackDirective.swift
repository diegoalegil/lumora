// SPDX-License-Identifier: MIT
// Provenance: clean-room.
import Foundation

/// What a renderer should be doing right now, as decided by the playback-policy engine.
/// The shell pushes this to whichever player is hosted (`setRenderingEnabled` + `setPreferredFrameRate`).
public struct PlaybackDirective: Sendable, Equatable {
    public var renderingEnabled: Bool
    public var targetFPS: Int

    public init(renderingEnabled: Bool, targetFPS: Int) {
        self.renderingEnabled = renderingEnabled
        self.targetFPS = max(0, targetFPS)
    }

    /// Render at full rate.
    public static let active = PlaybackDirective(renderingEnabled: true, targetFPS: 60)
    /// Stop rendering entirely (occluded / asleep / user-paused).
    public static let paused = PlaybackDirective(renderingEnabled: false, targetFPS: 0)
}

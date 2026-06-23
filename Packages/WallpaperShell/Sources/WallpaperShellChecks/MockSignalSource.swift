// SPDX-License-Identifier: MIT
// Provenance: clean-room test double for verifying PlaybackCoordinator without windows/IOKit.
import Foundation
import CoreGraphics
import WECore
import WallpaperShell

@MainActor
final class MockSignalSource: PlaybackSignalSource {
    var onChange: (() -> Void)?
    var base = PlaybackInputs()
    var occluded: Set<CGDirectDisplayID> = []

    private(set) var globalInputsCalls = 0
    func start() {}
    func stop() {}
    func globalInputs() -> PlaybackInputs { globalInputsCalls += 1; return base }
    func isOccluded(displayID: CGDirectDisplayID) -> Bool { occluded.contains(displayID) }

    /// Simulate a signal change.
    func fire() { onChange?() }
}

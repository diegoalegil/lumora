// SPDX-License-Identifier: MIT
// Provenance: clean-room. Abstracts the system signal sources so the coordinator is testable
// without real windows/IOKit (inject a mock in checks).
import Foundation
import CoreGraphics

@MainActor
public protocol PlaybackSignalSource: AnyObject {
    /// Invoked whenever any underlying signal changes; the coordinator re-evaluates.
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()

    /// Global inputs shared by every display. The `isOccluded` field is left at its default and
    /// filled per-display by the coordinator via `isOccluded(displayID:)`.
    func globalInputs() -> PlaybackInputs

    /// Whether the wallpaper window on the given display is currently occluded/hidden.
    func isOccluded(displayID: CGDirectDisplayID) -> Bool
}

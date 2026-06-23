// SPDX-License-Identifier: MIT
// Provenance: clean-room. Glues the signal source + policy engine and emits a per-display
// directive whenever signals change. The wiring is thin; the decision logic lives in the
// (pure, tested) PlaybackPolicyEngine.
import Foundation
import CoreGraphics
import WECore

@MainActor
public final class PlaybackCoordinator {
    private let engine: PlaybackPolicyEngine
    private let source: any PlaybackSignalSource
    private let displays: () -> [CGDirectDisplayID]

    /// Called with the resolved directive for each display on every re-evaluation.
    public var onDirective: ((CGDirectDisplayID, PlaybackDirective) -> Void)?

    public init(engine: PlaybackPolicyEngine = .init(),
                source: any PlaybackSignalSource,
                displays: @escaping () -> [CGDirectDisplayID]) {
        self.engine = engine
        self.source = source
        self.displays = displays
    }

    public func start() {
        source.onChange = { [weak self] in self?.evaluate() }
        source.start()
        evaluate()
    }

    public func stop() {
        source.stop()
    }

    /// Resolve the directive for a single display (also used standalone, e.g. on hotplug).
    public func directive(for displayID: CGDirectDisplayID) -> PlaybackDirective {
        var inputs = source.globalInputs()
        inputs.isOccluded = source.isOccluded(displayID: displayID)
        return engine.directive(for: inputs)
    }

    /// Recompute and emit directives for all current displays.
    public func evaluate() {
        // The global inputs (battery/thermal/low-power) are shared across displays and `globalInputs()` does
        // a live IOKit power snapshot, so take it ONCE per pass and vary only the per-display occlusion —
        // instead of N identical snapshots for N displays. Equivalent result (one instantaneous reading).
        let base = source.globalInputs()
        for id in displays() {
            var inputs = base
            inputs.isOccluded = source.isOccluded(displayID: id)
            onDirective?(id, engine.directive(for: inputs))
        }
    }
}

// SPDX-License-Identifier: MIT
// Provenance: clean-room. Classifies a screen-parameters change into the minimal work it implies, so a
// geometry-only change resizes the affected window in place (no GPU re-init flash) and a display whose frame
// didn't move isn't redrawn at all. Pure and AppKit-free (CGDirectDisplayID + CGRect only), so it's
// unit-tested with an injected before/after layout instead of real monitors.
import CoreGraphics

/// The result of comparing two desktop layouts (display id → frame): which displays appeared, disappeared,
/// merely moved/resized, or stayed put. A `didChangeScreenParameters` notification fires for any of these (and
/// for unrelated changes like a colour-profile switch), so the manager uses this to do only the work required.
public struct ScreenLayoutDiff: Equatable, Sendable {
    /// Present now but not before — needs a new window.
    public let added: [CGDirectDisplayID]
    /// Gone now — its window should be torn down.
    public let removed: [CGDirectDisplayID]
    /// Present in both but with a different frame — resize the existing window in place (keep its renderer).
    public let resized: [CGDirectDisplayID]
    /// Present in both with an identical frame — no work at all.
    public let unchanged: [CGDirectDisplayID]

    /// Classify the move from `old` to `new`. The arrays are sorted so the result is deterministic.
    public init(from old: [CGDirectDisplayID: CGRect], to new: [CGDirectDisplayID: CGRect]) {
        var added: [CGDirectDisplayID] = []
        var resized: [CGDirectDisplayID] = []
        var unchanged: [CGDirectDisplayID] = []
        for (id, frame) in new {
            if let oldFrame = old[id] {
                if oldFrame == frame { unchanged.append(id) } else { resized.append(id) }
            } else {
                added.append(id)
            }
        }
        let removed = old.keys.filter { new[$0] == nil }
        self.added = added.sorted()
        self.removed = removed.sorted()
        self.resized = resized.sorted()
        self.unchanged = unchanged.sorted()
    }

    /// True when no display was added, removed, or resized — the change was unrelated to geometry and the
    /// host can skip reacting (no window churn, no redraw).
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && resized.isEmpty }
}

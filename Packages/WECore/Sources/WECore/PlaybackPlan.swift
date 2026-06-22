// SPDX-License-Identifier: MIT
// Provenance: clean-room. Which playlist plays on which connected display, derived from the active playlist's
// display target — pure logic so the host can start/stop/restart only the displays that actually changed,
// fully unit-testable without AppKit.
import Foundation

/// The desktop playback plan: the playlist to run on each currently connected display. Built from the active
/// playlist and the set of connected display UUIDs, honouring the playlist's `displayTarget`.
public struct PlaybackPlan: Equatable, Sendable {
    public let byDisplay: [String: Playlist]

    public init(byDisplay: [String: Playlist] = [:]) { self.byDisplay = byDisplay }

    /// Resolve `active` across `connectedDisplays`: a `.all` playlist plays on every display; a
    /// `.display(uuid)` playlist plays only on that display; no active playlist means an empty plan.
    public init(active: Playlist?, connectedDisplays: [String]) {
        guard let active else { byDisplay = [:]; return }
        var map: [String: Playlist] = [:]
        for uuid in connectedDisplays {
            switch active.displayTarget {
            case .all:
                map[uuid] = active
            case .display(let target):
                if target == uuid { map[uuid] = active }
            }
        }
        byDisplay = map
    }

    public func playlist(forDisplay uuid: String) -> Playlist? { byDisplay[uuid] }
    public var isEmpty: Bool { byDisplay.isEmpty }
}

/// What changed between two plans, so the host updates only the affected displays: `started` displays gain a
/// playlist, `stopped` lose theirs, `restarted` switched to a DIFFERENT playlist (by id). A display whose
/// playlist kept the same id — even if its contents were edited — is left running (not in any list).
public struct PlaybackPlanDiff: Equatable, Sendable {
    public let started: [String]
    public let stopped: [String]
    public let restarted: [String]

    public init(from old: PlaybackPlan, to new: PlaybackPlan) {
        var started: [String] = [], stopped: [String] = [], restarted: [String] = []
        for (uuid, playlist) in new.byDisplay {
            if let existing = old.byDisplay[uuid] {
                if existing.id != playlist.id { restarted.append(uuid) }
            } else {
                started.append(uuid)
            }
        }
        for uuid in old.byDisplay.keys where new.byDisplay[uuid] == nil { stopped.append(uuid) }
        self.started = started.sorted()
        self.stopped = stopped.sorted()
        self.restarted = restarted.sorted()
    }

    public var isEmpty: Bool { started.isEmpty && stopped.isEmpty && restarted.isEmpty }
}

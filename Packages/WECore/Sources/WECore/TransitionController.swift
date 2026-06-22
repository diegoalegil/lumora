// SPDX-License-Identifier: MIT
// Provenance: clean-room. The cross-fade between one wallpaper and the next as a PURE state machine: it only
// computes opacities from an injected `now`, so the host can drive two overlapping renderers and know exactly
// when to release the old one — all unit-testable without a timer or Metal.
import Foundation

/// Drives a transition from an outgoing wallpaper to an incoming one. A cross-fade keeps BOTH renderers alive
/// and ramps opacity over `duration`; a `.none` transition (or zero duration) is an instant cut. The host
/// calls `begin` when switching, reads `incomingOpacity`/`outgoingOpacity` each frame, and `tick`s — which
/// reports the single moment the fade finishes so the old renderer can be torn down.
public struct TransitionController: Sendable {
    public enum Phase: Sendable, Equatable {
        /// One wallpaper on screen at full opacity.
        case idle
        /// Two wallpapers overlapped, opacity ramping.
        case crossfading
    }

    public private(set) var phase: Phase = .idle
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0

    public init() {}

    /// Begin a transition. `.none` or a non-positive/non-finite duration is an instant cut (phase stays/returns
    /// to `.idle`). Returns true if a cross-fade is now in progress (the host must keep the OLD renderer alive),
    /// false for a hard cut (the old renderer can be dropped immediately).
    @discardableResult
    public mutating func begin(_ kind: TransitionKind, duration rawDuration: TimeInterval, now: TimeInterval) -> Bool {
        let safeDuration = rawDuration.isFinite ? max(0, rawDuration) : 0
        guard kind == .crossfade, safeDuration > 0 else {
            phase = .idle
            return false
        }
        startTime = now
        duration = safeDuration
        phase = .crossfading
        return true
    }

    /// The incoming wallpaper's opacity at `now`: 0 at the start of a fade, ramping to 1 at the end; always 1
    /// when idle (the incoming wallpaper is simply the one on screen).
    public func incomingOpacity(at now: TimeInterval) -> Double {
        guard phase == .crossfading, duration > 0 else { return 1 }
        return min(1, max(0, (now - startTime) / duration))
    }

    /// The outgoing wallpaper's opacity at `now` — the complement of the incoming, fading to 0.
    public func outgoingOpacity(at now: TimeInterval) -> Double { 1 - incomingOpacity(at: now) }

    /// Advance the state. Returns true the single frame the cross-fade completes (the host then releases the
    /// outgoing renderer and the controller goes idle). Returns false otherwise.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        guard phase == .crossfading, now - startTime >= duration else { return false }
        phase = .idle
        startTime = 0
        duration = 0
        return true
    }
}

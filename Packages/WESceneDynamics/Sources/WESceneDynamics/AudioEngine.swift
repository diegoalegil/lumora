// SPDX-License-Identifier: MIT
// Provenance: clean-room. Captures system audio with ScreenCaptureKit (SCStream audio output — no virtual
// device needed), runs each window through AudioBandMapper, and publishes the latest 16/32/64 bands per
// channel as an AudioSpectrumProvider. Built from Apple ScreenCaptureKit/CoreMedia docs. No GPL.
//
// Permission: SCStream audio is gated by the system "Screen Recording" privacy permission (there is no
// audio-only permission). If permission is denied or capture can't start, the engine stays in its initial
// all-zero state — every wallpaper still renders, audio-reactive ones simply read silence.
import Foundation
import ScreenCaptureKit
import CoreMedia
import os
import WECore

public final class AudioEngine: NSObject, AudioSpectrumProvider, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    /// Published, lock-guarded latest bands. Read from the renderer (main); written from the capture queue.
    private struct Snapshot: Sendable {
        var left16 = [Float](repeating: 0, count: 16), right16 = [Float](repeating: 0, count: 16)
        var left32 = [Float](repeating: 0, count: 32), right32 = [Float](repeating: 0, count: 32)
        var left64 = [Float](repeating: 0, count: 64), right64 = [Float](repeating: 0, count: 64)
    }
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    private let captureQueue = DispatchQueue(label: "com.lumora.audio.capture", qos: .userInitiated)
    private let sampleRate: Float = 48_000
    private let windowSize = 1024
    // Capture-queue-only state (never touched off that queue):
    private let mapperLeft = AudioBandMapper(fftSize: 1024)
    private let mapperRight = AudioBandMapper(fftSize: 1024)
    private var accumLeft: [Float] = []
    private var accumRight: [Float] = []
    private var prev = Snapshot()
    private var lastTime = CACurrentMediaTimeOrZero()

    // `running` (is capture active?) and the live `stream` are control state touched from THREE contexts: the
    // main actor (start/stop, driven by playback policy + wallpaper switching), the detached startCapture
    // task, and the SCStream delegate queue. Confine every access to this lock so a stop() can never lose a
    // stream that startCapture is concurrently adopting — which would leak a live Screen-Recording capture
    // that nothing stops. SCStream isn't Sendable, so use the unchecked lock variant.
    private struct Control { var running = false; var stream: SCStream? }
    private let control = OSAllocatedUnfairLock(uncheckedState: Control())

    public override init() { super.init() }

    // MARK: AudioSpectrumProvider
    public func spectrum(bands: Int, channel: AudioChannel) -> [Float] {
        state.withLock { s in
            switch (bands, channel) {
            case (16, .left): return s.left16
            case (16, .right): return s.right16
            case (32, .left): return s.left32
            case (32, .right): return s.right32
            case (64, .left): return s.left64
            case (64, .right): return s.right64
            default: return Array(repeating: 0, count: max(0, bands))
            }
        }
    }

    // MARK: Lifecycle
    /// Begin capturing system audio. Idempotent; failure leaves the engine silent (no throw to the caller).
    public func start() {
        let begin = control.withLockUnchecked { c -> Bool in
            guard !c.running else { return false }
            c.running = true
            return true
        }
        guard begin else { return }
        Task { [weak self] in await self?.startCapture() }
    }

    /// Stop capturing and reset to silence so a paused wallpaper doesn't read stale bands.
    public func stop() {
        let active = control.withLockUnchecked { c -> SCStream? in
            c.running = false
            let s = c.stream
            c.stream = nil
            return s
        }
        if let active { Task { try? await active.stopCapture() } }
        state.withLock { $0 = Snapshot() }
        captureQueue.async { [weak self] in
            self?.accumLeft.removeAll(keepingCapacity: true)
            self?.accumRight.removeAll(keepingCapacity: true)
            self?.prev = Snapshot()
            // Reset to silence again ON the capture queue: it's serial, so this runs after any in-flight
            // sample buffer, giving silence the last word even if one slipped through.
            self?.state.withLock { $0 = Snapshot() }
        }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }   // no display → stay silent
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(sampleRate)
            config.channelCount = 2
            config.width = 2; config.height = 2          // minimal video (a display filter still drives one)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            // Adopt the started stream only if we're still meant to be running, atomically with respect to a
            // concurrent stop()/start(). If running flipped false while we were starting (stop won), or a prior
            // stream is already stored (a stop→start raced ahead of us), hand the loser back out and stop it —
            // so a capture is never left running with nothing tracking it.
            let abandoned: SCStream? = control.withLockUnchecked { c -> SCStream? in
                guard c.running else { return stream }   // stop() won — abandon the stream we just started
                let evicted = c.stream                   // a prior stream we're replacing (rare start/stop overlap)
                c.stream = stream
                return evicted
            }
            if let abandoned { try? await abandoned.stopCapture() }
        } catch {
            control.withLockUnchecked { $0.running = false }   // permission denied / unavailable → remain silent
        }
    }

    // MARK: SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        control.withLockUnchecked { c in c.running = false; c.stream = nil }
        state.withLock { $0 = Snapshot() }
    }

    // MARK: SCStreamOutput (capture queue)
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // A buffer can land on this queue just after stop() reset us to silence; drop it so it can't re-run the
        // FFT and repopulate non-zero bands (stop()'s capture-queue reset then has the last word).
        guard control.withLockUnchecked({ $0.running }) else { return }
        guard let (left, right) = Self.extractStereo(sampleBuffer) else { return }
        accumLeft.append(contentsOf: left)
        accumRight.append(contentsOf: right)
        // Need a full window in BOTH channels — otherwise `.suffix(windowSize)` would hand the mapper a short,
        // zero-padded right window.
        guard accumLeft.count >= windowSize, accumRight.count >= windowSize else { return }

        let now = CACurrentMediaTimeOrZero()
        let dt = Float(max(0, min(0.5, now - lastTime)))
        lastTime = now

        // Use the most recent window; keep a small tail so the next window overlaps slightly.
        let lWindow = Array(accumLeft.suffix(windowSize))
        let rWindow = Array(accumRight.suffix(windowSize))
        if accumLeft.count > windowSize * 2 { accumLeft.removeFirst(accumLeft.count - windowSize) }
        if accumRight.count > windowSize * 2 { accumRight.removeFirst(accumRight.count - windowSize) }

        guard let ml = mapperLeft, let mr = mapperRight else { return }
        var next = Snapshot()
        next.left16 = ml.bands(from: lWindow, count: 16, previous: prev.left16, frameTime: dt, sampleRate: sampleRate)
        next.left32 = ml.bands(from: lWindow, count: 32, previous: prev.left32, frameTime: dt, sampleRate: sampleRate)
        next.left64 = ml.bands(from: lWindow, count: 64, previous: prev.left64, frameTime: dt, sampleRate: sampleRate)
        next.right16 = mr.bands(from: rWindow, count: 16, previous: prev.right16, frameTime: dt, sampleRate: sampleRate)
        next.right32 = mr.bands(from: rWindow, count: 32, previous: prev.right32, frameTime: dt, sampleRate: sampleRate)
        next.right64 = mr.bands(from: rWindow, count: 64, previous: prev.right64, frameTime: dt, sampleRate: sampleRate)
        let snapshot = next
        prev = snapshot
        state.withLock { $0 = snapshot }
    }

    /// Pull deinterleaved L/R Float32 samples out of an audio CMSampleBuffer. Handles both layouts:
    /// non-interleaved (one buffer per channel) and interleaved (one buffer, channels packed). Mono
    /// duplicates to both. Returns nil if it isn't 32-bit float PCM we can read.
    private static func extractStereo(_ sampleBuffer: CMSampleBuffer) -> (left: [Float], right: [Float])? {
        var ablSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            ablSize > 0 else { return nil }
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        defer { ablRaw.deallocate() }
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let first = buffers.first, let data = first.mData else { return nil }

        if buffers.count >= 2, let rData = buffers[1].mData {   // non-interleaved: buffer per channel
            let lCount = Int(first.mDataByteSize) / 4
            let rCount = Int(buffers[1].mDataByteSize) / 4
            let left = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: lCount))
            let right = Array(UnsafeBufferPointer(start: rData.assumingMemoryBound(to: Float.self), count: rCount))
            return (left, right)
        }
        // Single buffer: interleaved (channels packed) or mono.
        let channels = max(1, Int(first.mNumberChannels))
        let total = Int(first.mDataByteSize) / 4
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: total)
        if channels == 1 { let mono = Array(samples); return (mono, mono) }
        var left = [Float](), right = [Float]()
        left.reserveCapacity(total / channels); right.reserveCapacity(total / channels)
        var i = 0
        while i + channels - 1 < total { left.append(samples[i]); right.append(samples[i + 1]); i += channels }
        return (left, right)
    }
}

/// Monotonic seconds, or 0 if unavailable — kept out of the band math so that stays pure/deterministic.
private func CACurrentMediaTimeOrZero() -> Double { ProcessInfo.processInfo.systemUptime }

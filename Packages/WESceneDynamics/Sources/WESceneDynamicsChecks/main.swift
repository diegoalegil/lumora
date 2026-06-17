// SPDX-License-Identifier: MIT
// Provenance: clean-room. Deterministic checks for the audio band math (no audio hardware needed).
import Foundation
import WECore
import WESceneDynamics

func sine(_ freq: Float, count: Int, sampleRate: Float = 48_000, amplitude: Float = 1) -> [Float] {
    (0 ..< count).map { amplitude * sin(2 * .pi * freq * Float($0) / sampleRate) }
}

guard let mapper = AudioBandMapper(fftSize: 1024) else {
    print("  ✗ AudioBandMapper failed to initialize"); exit(1)
}

Check.section("AudioBandMapper — shape & bounds")
let silent = mapper.bands(from: [Float](repeating: 0, count: 1024), count: 32)
Check.that("silence yields all-zero bands (graceful-degradation contract)", silent.allSatisfy { $0 == 0 })
for count in [16, 32, 64] {
    Check.that("returns exactly \(count) bands", mapper.bands(from: sine(1_000, count: 1024), count: count).count == count)
}
let loud = mapper.bands(from: sine(1_000, count: 1024, amplitude: 1.0), count: 32)
Check.that("every band is within 0…1", loud.allSatisfy { $0 >= 0 && $0 <= 1 })
let full = mapper.bands(from: sine(1_000, count: 1024, amplitude: 4.0), count: 32)   // clipping-loud
Check.that("an over-driven input still clamps to ≤ 1", full.allSatisfy { $0 <= 1 })

Check.section("AudioBandMapper — frequency localization")
// A pure tone should light its own band far more than a distant band.
func bandIndex(forHz hz: Float, count: Int, sampleRate: Float = 48_000) -> Int {
    let fLo: Float = 30, fHi = sampleRate / 2
    let ratio = log(hz / fLo) / log(fHi / fLo)
    return min(count - 1, max(0, Int(ratio * Float(count))))
}
for hz in [Float(200), 1_000, 6_000] {
    let bands = mapper.bands(from: sine(hz, count: 1024, amplitude: 1.0), count: 32)
    let target = bandIndex(forHz: hz, count: 32)
    let peak = bands.firstIndex(of: bands.max() ?? 0) ?? -1
    Check.that("a \(Int(hz)) Hz tone peaks at/near its band (\(target)±1, got \(peak))", abs(peak - target) <= 1)
}

Check.section("AudioBandMapper — determinism")
let a = mapper.bands(from: sine(1_000, count: 1024), count: 32)
let b = mapper.bands(from: sine(1_000, count: 1024), count: 32)
Check.that("same input → identical output", a == b)

Check.section("AudioBandMapper — attack/release decay")
let peak = mapper.bands(from: sine(1_000, count: 1024, amplitude: 1.0), count: 16)
let silentFrame = [Float](repeating: 0, count: 1024)
// Fall over silent frames at 60 fps: each band should be strictly decreasing and approach 0.
var prev = peak
var monotone = true
for _ in 0 ..< 20 {
    let next = mapper.bands(from: silentFrame, count: 16, previous: prev, frameTime: 1.0 / 60)
    for i in 0 ..< 16 where prev[i] > 0.001 && next[i] > prev[i] + 1e-5 { monotone = false }
    prev = next
}
Check.that("bands ease down monotonically over silent frames", monotone)
Check.that("bands have decayed near zero after 20 frames", prev.allSatisfy { $0 < 0.2 })
// Frame-rate independence: the same wall-clock elapsed should decay by ~the same amount at 30 vs 60 fps.
let oneStep60 = mapper.bands(from: silentFrame, count: 16, previous: peak, frameTime: 1.0 / 60)
var thirty = peak
for _ in 0 ..< 2 { thirty = mapper.bands(from: silentFrame, count: 16, previous: thirty, frameTime: 1.0 / 120) }
let close = zip(oneStep60, thirty).allSatisfy { abs($0 - $1) < 0.02 }
Check.that("decay is frame-rate independent (1×1/60 ≈ 2×1/120)", close)

Check.section("AudioEngine — silent until capture")
// The live engine can't capture in a headless/CLT run (no GUI session, no Screen Recording permission),
// but it must construct and report silence so audio-reactive shaders render flat instead of crashing.
let engine = AudioEngine()
Check.that("a fresh engine reports 16 zeros (left)", engine.spectrum(bands: 16, channel: .left) == Array(repeating: 0, count: 16))
Check.that("a fresh engine reports 32 zeros (right)", engine.spectrum(bands: 32, channel: .right) == Array(repeating: 0, count: 32))
Check.that("a fresh engine reports 64 zeros (left)", engine.spectrum(bands: 64, channel: .left) == Array(repeating: 0, count: 64))
Check.that("conforms to AudioSpectrumProvider", (engine as AudioSpectrumProvider).spectrum(bands: 16, channel: .left).count == 16)

Check.summarize()

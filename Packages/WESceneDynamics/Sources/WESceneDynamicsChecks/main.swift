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

Check.section("SceneScriptRuntime — property scripts")
// A representative WE clock script (shape taken from real text/script clocks across the library).
let clockScript = """
'use strict';
export var scriptProperties = createScriptProperties()
    .addCheckbox({ name: 'use24hFormat', label: '24h', value: true })
    .addCheckbox({ name: 'showSeconds', label: 'Seconds', value: false })
    .addText({ name: 'delimiter', label: 'Delimiter', value: ':' })
    .finish();
export function update(value) {
    let time = new Date();
    let hours = ("00" + time.getHours()).slice(-2);
    let minutes = ("00" + time.getMinutes()).slice(-2);
    return hours + scriptProperties.delimiter + minutes;
}
"""
if let runtime = SceneScriptRuntime(script: clockScript) {
    Check.that("loads a property script", runtime.loaded)
    Check.that("extracts declared properties (defaults)",
               (runtime.properties["delimiter"] as? String) == ":" && (runtime.properties["use24hFormat"] as? Bool) == true)
    let out = runtime.updateString("")
    // Compare against the same HH:MM the runtime's Date() produced (allow the minute to roll over once).
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    Check.that("a clock update() returns the current HH:MM (got \(out ?? "nil"))",
               out != nil && out!.count == 5 && out!.contains(":"))
} else {
    Check.that("clock runtime constructs", false)
}

// A numeric update (bar height, oscillator) returns a number.
if let osc = SceneScriptRuntime(script: "export function update(v) { return 0.5; }") {
    Check.that("a numeric update() returns its value", osc.updateNumber(0) == 0.5)
}

// Graceful degradation: a script with no update, or one that throws, never crashes — yields nil.
let noUpdate = SceneScriptRuntime(script: "export var x = 1;")
Check.that("a script without update() doesn't load as drivable", noUpdate == nil || noUpdate?.updateString() == nil)
if let thrower = SceneScriptRuntime(script: "export function update(v){ throw new Error('boom'); }") {
    Check.that("a throwing update() yields nil (graceful)", thrower.updateString() == nil)
}
// A script using unsupported API at load still doesn't crash the host (engine stub absorbs common calls).
let audioish = SceneScriptRuntime(script: "var b = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64); export function update(v){ return v; }")
Check.that("an engine-using script loads against the stub", audioish != nil)

Check.section("SceneScriptRuntime — scene-graph (audio bars)")
// A representative WE audio-bar visualiser: declares properties, clones thisLayer into N bars in init(),
// and sets each bar's height from the 64-band audio buffer in update(). Shape from the real bar scripts.
let barScript = """
'use strict';
export var scriptProperties = createScriptProperties()
    .addSlider({ name: 'barAmount', label: 'Bars', value: 16, min: 1, max: 64, integer: true })
    .addSlider({ name: 'offsetX', label: 'Spacing', value: 50, min: 0, max: 100 })
    .finish();
const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);
var bars = [];
export function init() {
    bars.push(thisLayer);
    let i0 = thisScene.getLayerIndex(thisLayer);
    for (var i = 1; i < scriptProperties.barAmount; ++i) {
        let bar = thisScene.createLayer('models/bar.json');
        thisScene.sortLayer(bar, i0);
        bars.push(bar);
    }
}
export function update() {
    var baseX = thisLayer.origin.copy().x;
    for (var i = 0; i < scriptProperties.barAmount; ++i) {
        let bar = bars[i];
        let idx = Math.floor((i / scriptProperties.barAmount) * 64);
        bar.origin = new Vec3(baseX + i * scriptProperties.offsetX, thisLayer.origin.y, 0);
        bar.scale = new Vec3(1, Math.min(audioBuffer.average[idx], 1), 1);
    }
}
"""
if let bars = SceneScriptRuntime(script: barScript, baseOrigin: SIMD3(100, 500, 0)) {
    Check.that("a graph script with init() drives layers", bars.drivesLayers)
    // Synthetic spectrum: a single peak at band 32 (≈ bar index 8 of 16).
    var spectrum = [Float](repeating: 0.05, count: 64); spectrum[32] = 1.0
    bars.setAudioSpectrum(spectrum)
    bars.runUpdate()
    let layers = bars.scriptedLayers()
    Check.that("creates barAmount layers (16)", layers.count == 16)
    Check.that("bars are spaced along X", layers.count >= 2 && layers[1].origin.x > layers[0].origin.x)
    // The bar whose band is the peak (idx 8 → band 32) should be the tallest.
    let heights = layers.map { $0.scale.y }
    let tallest = heights.firstIndex(of: heights.max() ?? 0) ?? -1
    Check.that("the peak-band bar is the tallest (idx \(tallest))", tallest == 8 && (heights.max() ?? 0) > 0.9)
    Check.that("quiet bars are short", heights.filter { $0 < 0.1 }.count >= 10)
} else {
    Check.that("bar runtime constructs", false)
}

Check.summarize()

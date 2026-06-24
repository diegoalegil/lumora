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

Check.section("AudioBandMapper — degenerate input guards")
// A bogus sample rate must not crash: zero/negative/NaN make the bin width zero or NaN, and the bin-index
// math would otherwise trap on an infinite/NaN Int conversion. The contract is graceful degradation to flat
// (silent) bands of the requested length.
let window = sine(1_000, count: 1024, amplitude: 1.0)
for badRate in [Float(0), -48_000, .nan, .infinity] {
    let degraded = mapper.bands(from: window, count: 16, sampleRate: badRate)
    Check.that("sampleRate \(badRate) degrades to 16 flat bands (no trap)",
               degraded.count == 16 && degraded.allSatisfy { $0 == 0 })
}
// count ≤ 0 is the "no bands requested" case and returns empty rather than looping.
Check.that("count 0 returns an empty band array", mapper.bands(from: window, count: 0).isEmpty)
Check.that("a negative count returns an empty band array", mapper.bands(from: window, count: -4).isEmpty)
// At 64 bands the lowest few are narrower than one FFT bin, exercising the nearest-bin fallback. Lock that it
// still yields finite, in-range bands (a wrong center index would read out of range or produce NaN) and that
// a mid tone still localizes.
let band64 = mapper.bands(from: window, count: 64)
Check.that("64 bands stay finite and within 0…1 (nearest-bin fallback intact)",
           band64.count == 64 && band64.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
Check.that("a 1 kHz tone still localizes at 64 bands",
           abs((band64.firstIndex(of: band64.max() ?? 0) ?? -1) - bandIndex(forHz: 1_000, count: 64)) <= 1)

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
    // The runtime formats its own `new Date()` internally; the test can't share that exact instant, so verify
    // the HH:MM shape rather than a value comparison.
    Check.that("a clock update() returns an HH:MM string (got \(out ?? "nil"))",
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

// Stripping the ES-module `export ` keyword must NOT corrupt an "export " that appears inside a STRING LITERAL
// (a script that returns or builds source text). Only a real statement-boundary `export ` is neutralised.
if let strLit = SceneScriptRuntime(script: "export function update(v){ return \"export function x(){}\"; }") {
    Check.that("export inside a string literal is preserved (not stripped)",
               strLit.updateString("") == "export function x(){}")
} else {
    Check.that("string-literal-export script loads", false)
}
// A mid-line `export` after a `;` is still neutralised (statement-boundary strip, not just line-start).
if let midline = SceneScriptRuntime(script: "var k = 1; export function update(v){ return v; }") {
    Check.that("a mid-line export (after ;) still loads", midline.updateString("ok") == "ok")
}
// A script returning a non-finite number (Infinity/NaN) must yield nil, not drive a layer transform into a
// GPU-undefined NaN — the caller keeps its static value (matches updateString's reject-non-string contract).
if let inf = SceneScriptRuntime(script: "export function update(v){ return 1/0; }") {
    Check.that("an Infinity update() number yields nil (graceful)", inf.updateNumber(0) == nil)
}
if let nan = SceneScriptRuntime(script: "export function update(v){ return 0/0; }") {
    Check.that("a NaN update() number yields nil (graceful)", nan.updateNumber(0) == nil)
}
if let fin = SceneScriptRuntime(script: "export function update(v){ return 0.5; }") {
    Check.that("a finite update() number still returns", fin.updateNumber(0) == 0.5)
}

// A real WE "3D clock" module: it `import`s WEMath and tilts itself toward the cursor with Vec3 arithmetic
// (origin.subtract(cursor).divide(canvasSize).multiply(50) + WEMath.mix). JavaScriptCore can't run ES-module
// `import`, so before this support the whole module failed to define update() and the editor placeholder
// ("<3D Clock>") rendered instead of the time. Verify the module loads and update() returns the HH:MM:SS time.
let clock3D = """
'use strict';
import * as WEMath from 'WEMath';
let delimiter = ':';
var shadowLayer;
export function update(value) {
    let time = new Date();
    let hours = ("00" + time.getHours()).slice(-2);
    let minutes = ("00" + time.getMinutes()).slice(-2);
    let seconds = ("00" + time.getSeconds()).slice(-2);
    value = hours + delimiter + minutes + delimiter + seconds;
    var delta = thisLayer.origin.subtract(input.cursorWorldPosition);
    delta = delta.divide(new Vec3(engine.canvasSize, 1));
    var rotation = new Vec3(delta.y, -delta.x, 4 * WEMath.mix(delta.x, -delta.x, Math.min(1, Math.max(0, delta.y * 0.1 + 0.5)))).multiply(50);
    thisLayer.angles = rotation;
    shadowLayer.text = value;
    return value;
}
export function init() {
    shadowLayer = thisScene.createLayer({ text: 'shadow', color: '0 0 0', alpha: 1, pointsize: thisLayer.pointsize, font: thisLayer.font, perspective: true });
    shadowLayer.origin = thisLayer.origin;
}
"""
if let clock = SceneScriptRuntime(script: clock3D, baseOrigin: SIMD3(300, 200, 0)) {
    Check.that("a WEMath-importing 3D-clock module loads (import stripped, helper provided)", clock.loaded)
    let out = clock.updateString("")
    Check.that("the 3D clock update() returns HH:MM:SS, not the placeholder (got \(out ?? "nil"))",
               out != nil && out!.count == 8 && out!.filter { $0 == ":" }.count == 2)
} else {
    Check.that("3D-clock runtime constructs", false)
}
// WEMath helpers behave like their GLSL namesakes; Vec3 arithmetic returns the expected components.
if let m = SceneScriptRuntime(script: """
export function update(v) {
    var a = new Vec3(1, 2, 3).add(new Vec3(4, 5, 6));       // (5,7,9)
    var b = new Vec3(10, 20, 30).divide(new Vec3(2, 4, 5)); // (5,5,6)
    return WEMath.clamp(WEMath.mix(0, 10, 0.5), 0, 4) + a.x + b.z; // 4 + 5 + 6 = 15
}
""") {
    Check.that("WEMath + Vec3 arithmetic compute correctly", m.updateNumber(0) == 15)
}
// A multi-line `import { ... } from 'X'` (braces spanning newlines) must be stripped too, not just the
// single-line form — otherwise the dangling tokens abort the module and update() is never defined.
if let multi = SceneScriptRuntime(script: """
import {
    mix,
    clamp
} from 'WEMath';
export function update(v) { return WEMath.clamp(WEMath.mix(0, 10, 0.5), 0, 4); }
""") {
    Check.that("a multi-line brace import is stripped and the module loads", multi.loaded && multi.updateNumber(0) == 4)
} else {
    Check.that("multi-line-import runtime constructs", false)
}
// A non-finite base origin/colour/alpha (a corrupt .pkg) must not abort the prelude: it's coerced to a finite
// number so a valid script still loads and runs.
if let nf = SceneScriptRuntime(script: "export function update(v){ return 0.5; }",
                               baseOrigin: SIMD3(.nan, .infinity, 0), baseColor: SIMD3(1, -.infinity, 1), baseAlpha: .nan) {
    Check.that("a non-finite base value doesn't break the prelude", nf.loaded && nf.updateNumber(0) == 0.5)
} else {
    Check.that("non-finite-base runtime constructs", false)
}

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
var baseOrigin;
export function init() {
    bars.push(thisLayer);
    let i0 = thisScene.getLayerIndex(thisLayer);
    for (var i = 1; i < scriptProperties.barAmount; ++i) {
        let bar = thisScene.createLayer('models/bar.json');
        thisScene.sortLayer(bar, i0);
        bars.push(bar);
    }
    baseOrigin = thisLayer.origin;
}
export function update() {
    // The real bar scripts reuse ONE origin/scale object, mutate it, and assign it to each bar — relying on
    // the layer setter to COPY. This exercises that semantic (without copying, every bar aliases one object).
    var origin = baseOrigin.copy();
    var scale = new Vec3(1, 0, 1);
    for (var i = 0; i < scriptProperties.barAmount; ++i) {
        let idx = Math.floor((i / scriptProperties.barAmount) * 64);
        scale.y = Math.min(audioBuffer.average[idx], 1);
        origin.x += scriptProperties.offsetX;
        bars[i].scale = scale;
        bars[i].origin = origin;
        bars[i].alignment = 'bottom';
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
    Check.that("the bar's pivot alignment is read back (for the renderer's grow direction)",
               layers.allSatisfy { $0.alignment == "bottom" })
} else {
    Check.that("bar runtime constructs", false)
}

// Untrusted scene JS can set a transform component to NaN/±Inf (e.g. a divide by zero). The readback must
// clamp every component to the layer default so a non-finite value never reaches the Metal bar vertex shader.
if let nf = SceneScriptRuntime(script: "export function update(v){ thisLayer.origin = new Vec3(0/0, 1/0, 0); thisLayer.scale = new Vec3(-1/0, 1, 1); return 0; }") {
    nf.runUpdate()
    Check.that("non-finite scripted transforms are clamped finite", nf.scriptedLayers().allSatisfy {
        $0.origin.x.isFinite && $0.origin.y.isFinite && $0.origin.z.isFinite
            && $0.scale.x.isFinite && $0.scale.y.isFinite && $0.scale.z.isFinite
            && $0.alpha.isFinite && $0.color.x.isFinite
    })
} else {
    Check.that("non-finite scripted-transform runtime constructs", false)
}

Check.section("SceneScriptRuntime — execution watchdog (DoS guard)")
// A hostile/buggy script must not hang the render thread: an infinite loop in update() has to be aborted by
// the execution-time-limit watchdog and yield nil. The real proof is that the call RETURNS at all — an
// un-aborted loop would hang this process forever and never reach the check below. The wall clock is only a
// loose sanity ceiling, kept far above the 0.25s limit so CI scheduling jitter can't turn it into a flake.
if let spinner = SceneScriptRuntime(script: "export function update(v){ while(true){} }") {
    let start = Date()
    let result = spinner.updateString()
    let elapsed = Date().timeIntervalSince(start)
    Check.that("an infinite-loop update() is aborted (returns nil)", result == nil)
    Check.that("it doesn't run unbounded (\(String(format: "%.2f", elapsed))s, under a generous ceiling)",
               elapsed < SceneScriptRuntime.executionTimeLimitSeconds * 40)
    // The watchdog bounds each call, it doesn't poison JavaScriptCore process-wide: a FRESH runtime must still
    // execute normally after an abort (re-calling the spinner would just abort again — that proves nothing).
    if let healthy = SceneScriptRuntime(script: "export function update(v){ return 0.5; }") {
        Check.that("a fresh runtime still works after an abort", healthy.updateNumber(0) == 0.5)
    } else {
        Check.that("post-abort runtime constructs", false)
    }
} else {
    Check.that("spinner runtime constructs", false)
}
// An infinite loop in init() must not hang construction either (init runs under the same limit). Construction
// reaching here at all proves no hang; assert a real post-condition — the runtime still loads and update() runs.
let initSpin = SceneScriptRuntime(script: "export function init(){ while(true){} }\nexport function update(v){ return v; }")
Check.that("an infinite-loop init() doesn't hang construction and update() still runs",
           initSpin != nil && initSpin?.updateString("ok") == "ok")

Check.summarize()

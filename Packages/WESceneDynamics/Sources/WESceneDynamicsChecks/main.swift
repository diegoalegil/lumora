// SPDX-License-Identifier: MIT
// Provenance: clean-room. Deterministic checks for the SceneScript runtime (clocks, audio-bar visualisers
// driven by an injected spectrum, the execution watchdog) — no audio hardware or GUI session needed.
import Foundation
import WECore
import WESceneDynamics

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

// engine.time and frametime are now driven live each frame (F08): a time-driven script reads the elapsed
// seconds and the real per-frame dt we set, instead of the frozen 0 / constant 1/60 they used to read forever.
if let t = SceneScriptRuntime(script: "export function update(v){ return engine.time; }") {
    Check.that("engine.time defaults to 0 before setTime", t.updateNumber(0) == 0)
    t.setTime(5)
    Check.that("setTime feeds engine.time", t.updateNumber(0) == 5)
    t.setTime(42.5)
    Check.that("engine.time is live, not frozen at 0", t.updateNumber(0) == 42.5)
    t.setTime(.infinity)
    Check.that("a non-finite time coerces to 0", t.updateNumber(0) == 0)
}
if let ft = SceneScriptRuntime(script: "export function update(v){ return engine.frametime + engine.getFrameTime(); }") {
    Check.that("frametime + getFrameTime() default to ~2/60", abs((ft.updateNumber(0) ?? 0) - 2 * 0.0166667) < 1e-6)
    ft.setFrameTime(0.02)
    Check.that("setFrameTime updates both frametime and getFrameTime()", abs((ft.updateNumber(0) ?? 0) - 0.04) < 1e-9)
    ft.setFrameTime(-1)
    Check.that("a non-positive dt clamps to the 1/60 default", abs((ft.updateNumber(0) ?? 0) - 2 * 0.0166667) < 1e-6)
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

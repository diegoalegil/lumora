// SPDX-License-Identifier: MIT
// Provenance: clean-room. Runs Wallpaper Engine "SceneScript" property scripts on JavaScriptCore. WE binds a
// small JS module to a scene property: it declares user `scriptProperties` and exports `init()`/`update(value)`
// which the engine calls per frame to drive the property — a clock text's `text`, or an audio visualiser's
// `scale` that clones `thisLayer` into N bars and sets each one's height from the audio spectrum. This runs
// that module and exposes its result + the layers it manipulates. The host API (createScriptProperties, a
// minimal `engine`, Vec2/Vec3, thisLayer/thisScene with createLayer, an audio buffer) is reconstructed from
// observed script usage + public WE docs; no GPL. DEGRADES GRACEFULLY: a script that throws or uses an
// unsupported call yields nil / no scripted layers, so the caller keeps the static value — a scripted
// property is never rendered wrong, only un-animated.
import Foundation
import simd
import JavaScriptCore
import CJSWatchdog

public final class SceneScriptRuntime {
    /// One layer the script created or manipulates (the base `thisLayer` plus any `createLayer` clones),
    /// read back after `runUpdate()` so the renderer can draw the bars/elements the script produced.
    public struct ScriptedLayer: Sendable, Equatable {
        public var origin: SIMD3<Float>
        public var scale: SIMD3<Float>
        public var color: SIMD3<Float>
        public var alpha: Float
        public var model: String?     // createLayer('models/bar.json') source; nil for the base layer
        public var alignment: String? // 'centre' | 'bottom' | 'top' — the pivot the bar scales about
    }

    /// Wall-clock ceiling for any single JS evaluation/call. A per-frame clock/visualiser script runs in
    /// microseconds; 0.25 s is far above that yet aborts an infinite loop well within one frame's budget.
    public static let executionTimeLimitSeconds = 0.25

    private let context: JSContext
    private var updateFn: JSValue?
    /// True when this script manipulates the scene graph (created layers / has init) vs a plain value script.
    public private(set) var drivesLayers = false
    public private(set) var properties: [String: Any] = [:]
    public private(set) var loaded = false

    /// Build a runtime for one property script. `baseOrigin/baseColor/baseAlpha` seed `thisLayer` (the scene
    /// object the script is attached to). Returns nil only if JavaScriptCore can't be created.
    public init?(script: String, baseOrigin: SIMD3<Float> = .zero,
                 baseColor: SIMD3<Float> = SIMD3(1, 1, 1), baseAlpha: Float = 1) {
        guard let context = JSContext() else { return nil }
        self.context = context
        context.exceptionHandler = { _, _ in }   // swallow; loaded stays false / results are nil
        // Watchdog: a hostile or buggy `.pkg` could ship `while(true){}` in init()/update(), which runs
        // synchronously on the render thread (clock strings, audio-bar transforms). Bound every JS evaluation
        // and call so JavaScriptCore aborts a runaway one (raising an exception the handler above swallows →
        // the script just yields no value, the static fallback stays). The limit is generous vs any real
        // per-frame script yet trips a spin loop in a fraction of a frame.
        lumora_set_js_execution_time_limit(context.jsGlobalContextRef, Self.executionTimeLimitSeconds)

        // A corrupt .pkg could carry a non-finite base origin/colour/alpha; interpolated raw it becomes the
        // JS literal `nan`/`inf`, a syntax error that aborts the WHOLE prelude (so even valid scripts break).
        // Coerce to a finite number first.
        func jsNum(_ x: Float) -> String { x.isFinite ? "\(x)" : "0" }

        let prelude = """
        function Vec2(x, y) {
            if (x !== null && typeof x === 'object' && 'x' in x) { this.x = x.x || 0; this.y = (y === undefined ? (x.y || 0) : y); return; }
            this.x = x || 0; this.y = (y === undefined ? (x || 0) : y);
        }
        Vec2.prototype.copy = function () { return new Vec2(this.x, this.y); };
        // WE's Vec3 has a spread constructor: `new Vec3(someVec, z)` lifts a Vec2/Vec3's x,y and takes z from the
        // 2nd arg (a clock script does `new Vec3(engine.canvasSize, 1)`). Keep the scalar path byte-identical to
        // before so existing audio-bar scripts are unaffected; only add the object branch.
        function Vec3(x, y, z) {
            if (x !== null && typeof x === 'object' && 'x' in x) { this.x = x.x || 0; this.y = (x.y || 0); this.z = (y === undefined ? (x.z || 0) : y); return; }
            this.x = x || 0; this.y = (y === undefined ? (x || 0) : y); this.z = (z === undefined ? (x || 0) : z);
        }
        Vec3.prototype.copy = function () { return new Vec3(this.x, this.y, this.z); };
        // Component-wise arithmetic taking a vector OR a scalar operand, matching WE's Vec2/Vec3. A scripted
        // clock tilts itself with `origin.subtract(cursor).divide(canvasSize).multiply(50)`; without these the
        // call throws and the whole script yields nil → the editor placeholder ("<Clock>") would be drawn.
        function __v3(o) { return (o !== null && typeof o === 'object' && 'x' in o) ? o : new Vec3(o, o, o); }
        function __v2(o) { return (o !== null && typeof o === 'object' && 'x' in o) ? o : new Vec2(o, o); }
        Vec3.prototype.add = function (o) { o = __v3(o); return new Vec3(this.x + o.x, this.y + o.y, this.z + o.z); };
        Vec3.prototype.subtract = function (o) { o = __v3(o); return new Vec3(this.x - o.x, this.y - o.y, this.z - o.z); };
        Vec3.prototype.multiply = function (o) { o = __v3(o); return new Vec3(this.x * o.x, this.y * o.y, this.z * o.z); };
        Vec3.prototype.divide = function (o) { o = __v3(o); return new Vec3(this.x / o.x, this.y / o.y, this.z / o.z); };
        Vec3.prototype.dot = function (o) { o = __v3(o); return this.x * o.x + this.y * o.y + this.z * o.z; };
        Vec3.prototype.length = function () { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); };
        Vec3.prototype.normalize = function () { var l = this.length() || 1; return new Vec3(this.x / l, this.y / l, this.z / l); };
        Vec3.prototype.sub = Vec3.prototype.subtract; Vec3.prototype.mul = Vec3.prototype.multiply; Vec3.prototype.div = Vec3.prototype.divide;
        Vec2.prototype.add = function (o) { o = __v2(o); return new Vec2(this.x + o.x, this.y + o.y); };
        Vec2.prototype.subtract = function (o) { o = __v2(o); return new Vec2(this.x - o.x, this.y - o.y); };
        Vec2.prototype.multiply = function (o) { o = __v2(o); return new Vec2(this.x * o.x, this.y * o.y); };
        Vec2.prototype.divide = function (o) { o = __v2(o); return new Vec2(this.x / o.x, this.y / o.y); };
        Vec2.prototype.length = function () { return Math.sqrt(this.x * this.x + this.y * this.y); };
        Vec2.prototype.sub = Vec2.prototype.subtract; Vec2.prototype.mul = Vec2.prototype.multiply; Vec2.prototype.div = Vec2.prototype.divide;
        // WEMath: WE's shader-math helper module that clock/visualiser scripts `import`. Reconstructed from
        // public WE docs + observed usage (mix/clamp/etc. are standard GLSL-style helpers); no GPL source read.
        var WEMath = {
            mix: function (a, b, t) { return a + (b - a) * t; },
            lerp: function (a, b, t) { return a + (b - a) * t; },
            clamp: function (x, lo, hi) { return Math.min(hi, Math.max(lo, x)); },
            saturate: function (x) { return Math.min(1, Math.max(0, x)); },
            smoothstep: function (e0, e1, x) { var t = Math.min(1, Math.max(0, (x - e0) / ((e1 - e0) || 1))); return t * t * (3 - 2 * t); },
            step: function (e, x) { return x < e ? 0 : 1; },
            sign: function (x) { return Math.sign(x); },
            fract: function (x) { return x - Math.floor(x); },
            mod: function (x, m) { return x - m * Math.floor(x / m); },
            radians: function (d) { return d * Math.PI / 180; },
            degrees: function (r) { return r * 180 / Math.PI; },
            PI: Math.PI
        };
        var __layers = [];
        // WE's layer property setters COPY the assigned vector — a script that does `bar.origin = origin`
        // then mutates `origin` in a loop (the bar visualisers do exactly this to space N bars) must leave
        // each bar with its own snapshot. Plain JS would alias them all to one object, so define vec
        // properties with copying setters.
        function __copyVec(v) {
            if (v && typeof v === 'object' && 'x' in v) {
                return ('z' in v) ? new Vec3(v.x, v.y, v.z) : new Vec2(v.x, v.y);
            }
            return v;
        }
        function __mkLayer(model, origin, color, alpha) {
            var L = { model: model, alignment: 'centre', alpha: alpha };
            var _o = __copyVec(origin), _s = new Vec3(1, 1, 1), _c = __copyVec(color), _a = new Vec3(0, 0, 0), _p = new Vec2(0, 0);
            Object.defineProperty(L, 'origin', { get: function () { return _o; }, set: function (v) { _o = __copyVec(v); }, enumerable: true });
            Object.defineProperty(L, 'scale', { get: function () { return _s; }, set: function (v) { _s = __copyVec(v); }, enumerable: true });
            Object.defineProperty(L, 'color', { get: function () { return _c; }, set: function (v) { _c = __copyVec(v); }, enumerable: true });
            Object.defineProperty(L, 'angles', { get: function () { return _a; }, set: function (v) { _a = __copyVec(v); }, enumerable: true });
            Object.defineProperty(L, 'parallaxDepth', { get: function () { return _p; }, set: function (v) { _p = __copyVec(v); }, enumerable: true });
            __layers.push(L); return L;
        }
        var thisLayer = __mkLayer(null, new Vec3(\(jsNum(baseOrigin.x)), \(jsNum(baseOrigin.y)), \(jsNum(baseOrigin.z))),
                                  new Vec3(\(jsNum(baseColor.x)), \(jsNum(baseColor.y)), \(jsNum(baseColor.z))), \(jsNum(baseAlpha)));
        var thisScene = {
            getLayerIndex: function (l) { return Math.max(0, __layers.indexOf(l)); },
            createLayer: function (model) { return __mkLayer(model, thisLayer.origin.copy(), thisLayer.color.copy(), thisLayer.alpha); },
            sortLayer: function (l, idx) {},
            getLayer: function () { return thisLayer; }
        };
        var __audio = { average: new Array(65).fill(0), length: 64 };
        function createScriptProperties() {
            var props = {};
            function rec(o) { if (o && o.name !== undefined) props[o.name] = o.value; return b; }
            var b = {
                addSlider: rec, addCheckbox: rec, addText: rec, addColor: rec,
                addCombo: function (o) { if (o && o.name !== undefined) props[o.name] = (o.value !== undefined ? o.value : (o.options && o.options[0] ? o.options[0].value : 0)); return b; },
                finish: function () { return props; }
            };
            return b;
        }
        var engine = {
            AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
            registerAudioBuffers: function () { return __audio; },
            getArrayValues: function () { return []; },
            canvasSize: new Vec2(1920, 1080),
            frametime: 0.0166667,
            time: 0,
            getFrameTime: function () { return 0.0166667; }
        };
        // Pointer state a cursor-reactive script reads (an interactive 3D clock tilts toward the mouse). A
        // rendered wallpaper has no live cursor, so default it to the layer's own origin: the script's
        // `origin.subtract(cursorWorldPosition)` delta is then zero → no tilt, exactly like the mouse resting
        // on the clock. Without this the script throws on the missing `input` and falls back to the placeholder.
        var input = {
            cursorWorldPosition: thisLayer.origin.copy(),
            mousePosition: new Vec2(0.5, 0.5),
            pointerPosition: new Vec2(0.5, 0.5)
        };
        """
        context.evaluateScript(prelude)
        // WE SceneScript is an ES module: it `export`s update()/init()/scriptProperties and may `import` a WE
        // helper module (e.g. `import * as WEMath from 'WEMath';`). JavaScriptCore's evaluateScript runs plain
        // scripts, where `export`/`import` are syntax errors that abort the WHOLE module — so a clock that
        // imports WEMath would fail to define update() and the editor placeholder ("<3D Clock>") would render
        // instead of the time. Neutralise the module wrappers: drop each `import` line (the helper it names is
        // provided as a prelude global) and strip the `export ` keyword so the declarations become plain globals.
        // The import match ends at the statement's `;` (or end of line) so any code after a same-line import is
        // preserved. `export ` is stripped only at a STATEMENT BOUNDARY — start of line, or right after `;`/`{`/`}`
        // — which still neutralises a mid-line `…; export function…` yet leaves an "export " INSIDE a string
        // literal (e.g. `return "export function …";`, preceded by `"`) intact.
        let moduleStripped = script
            // A `import { a, b } from 'X';` whose braces span newlines isn't caught by the line form below
            // (which stops at the first newline), leaving dangling tokens that abort the module. Strip the
            // whole brace import first: the `{…}` may contain newlines, ending at the statement's `;`.
            .replacingOccurrences(of: "(?m)^[ \\t]*import\\b[^;{}]*\\{[^}]*\\}[^;\\n]*;?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^[ \\t]*import\\b[^;\\n]*(?:;|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)(^[ \\t]*|[;{}][ \\t]*)export[ \\t]+", with: "$1", options: .regularExpression)
        context.evaluateScript(moduleStripped)

        if let props = context.objectForKeyedSubscript("scriptProperties"), !props.isUndefined,
           let dict = props.toDictionary() as? [String: Any] { properties = dict }
        guard let update = context.objectForKeyedSubscript("update"), update.isObject else { return nil }
        updateFn = update
        if let initFn = context.objectForKeyedSubscript("init"), initFn.isObject {
            drivesLayers = true
            _ = initFn.call(withArguments: [])
        }
        loaded = true
    }

    /// Set the audio spectrum the script reads as `audioBuffer.average[i]` (0…63, plus a guard slot). Call
    /// each frame before `runUpdate()` for an audio-reactive script.
    public func setAudioSpectrum(_ bands: [Float]) {
        guard loaded, let audio = context.objectForKeyedSubscript("__audio") else { return }
        var values = bands.map { NSNumber(value: $0) }
        values.append(NSNumber(value: bands.last ?? 0))   // the bar script reads dataIndex+1
        audio.setObject(values, forKeyedSubscript: "average" as NSString)
    }

    /// Run `update(value)` (the per-frame driver). Use updateString/Number to read a value result, or
    /// scriptedLayers() to read the layers a graph script produced.
    @discardableResult public func runUpdate(_ value: Any = 0) -> JSValue? {
        guard loaded else { return nil }
        return updateFn?.call(withArguments: [value])
    }

    public func updateString(_ value: String = "") -> String? {
        guard let r = runUpdate(value), !r.isUndefined, !r.isNull, r.isString else { return nil }
        return r.toString()
    }

    public func updateNumber(_ value: Double = 0) -> Double? {
        guard let r = runUpdate(value), !r.isUndefined, !r.isNull, r.isNumber else { return nil }
        // A script can return a non-finite number (`return 1/0` → Infinity, `0/0` → NaN). Reject it rather than
        // let it drive a layer's scale/alpha/position into a NaN the GPU treats as undefined — same finite
        // contract scriptedLayers() enforces. The caller keeps its static value.
        let result = r.toDouble()
        return result.isFinite ? result : nil
    }

    /// The layers the script owns (base `thisLayer` + `createLayer` clones), with their current transforms —
    /// read after `runUpdate()`. Empty for a plain value script.
    public func scriptedLayers() -> [ScriptedLayer] {
        guard loaded, let array = context.objectForKeyedSubscript("__layers"), array.isObject,
              let count = array.objectForKeyedSubscript("length")?.toNumber()?.intValue, count > 0 else { return [] }
        var result: [ScriptedLayer] = []
        for i in 0 ..< min(count, 4096) {
            guard let layer = array.objectAtIndexedSubscript(i), layer.isObject else { continue }
            // The script is untrusted .pkg JS; it can set a transform component to NaN/±Inf (e.g. a divide by
            // zero). Clamp each readback to the layer default so a non-finite value never reaches the Metal
            // bar vertex shader as a non-finite position/scale (GPU-undefined), matching the renderer's own
            // .isFinite convention.
            func finite(_ x: Double, _ d: Float) -> Float { let f = Float(x); return f.isFinite ? f : d }
            func vec3(_ key: String, _ d: SIMD3<Float>) -> SIMD3<Float> {
                guard let v = layer.objectForKeyedSubscript(key), v.isObject else { return d }
                return SIMD3(finite(v.objectForKeyedSubscript("x")?.toDouble() ?? Double(d.x), d.x),
                             finite(v.objectForKeyedSubscript("y")?.toDouble() ?? Double(d.y), d.y),
                             finite(v.objectForKeyedSubscript("z")?.toDouble() ?? Double(d.z), d.z))
            }
            result.append(ScriptedLayer(
                origin: vec3("origin", .zero),
                scale: vec3("scale", SIMD3(1, 1, 1)),
                color: vec3("color", SIMD3(1, 1, 1)),
                alpha: finite(layer.objectForKeyedSubscript("alpha")?.toDouble() ?? 1, 1),
                model: layer.objectForKeyedSubscript("model").flatMap { $0.isString ? $0.toString() : nil },
                alignment: layer.objectForKeyedSubscript("alignment").flatMap { $0.isString ? $0.toString() : nil }))
        }
        return result
    }
}

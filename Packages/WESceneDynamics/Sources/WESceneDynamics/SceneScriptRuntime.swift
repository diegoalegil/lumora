// SPDX-License-Identifier: MIT
// Provenance: clean-room. Runs Wallpaper Engine "SceneScript" property scripts on JavaScriptCore. WE binds
// a small JS module to a scene property (e.g. a clock text layer's `text`, a bar's `scale`): it declares
// user-editable `scriptProperties` and exports `init()`/`update(value)`, and the engine calls `update` each
// frame to drive the property. This runs that module and exposes its update result. The host API surface
// (createScriptProperties, a minimal `engine`) is reconstructed from observed script usage + public WE docs;
// no GPL. Designed to DEGRADE GRACEFULLY: a script that throws or uses an unsupported call yields nil, so the
// caller keeps the static value — a scripted property is never rendered wrong, only un-animated.
import Foundation
import JavaScriptCore

public final class SceneScriptRuntime {
    private let context: JSContext
    private var updateFn: JSValue?
    private var hasInit = false
    /// The script's declared user properties (name → default value), from `createScriptProperties()`.
    public private(set) var properties: [String: Any] = [:]
    public private(set) var loaded = false

    /// Build a runtime for one property script. Returns nil only if JavaScriptCore can't be created.
    public init?(script: String) {
        guard let context = JSContext() else { return nil }
        self.context = context
        context.exceptionHandler = { _, _ in }   // swallow; loaded stays false / update returns nil
        // Host API the scripts call at module-load and per-frame. createScriptProperties records declared
        // defaults; the minimal `engine` stub keeps audio/util-using scripts from throwing at load (audio
        // bands stay zero here — the live spectrum is wired separately).
        let prelude = """
        function createScriptProperties() {
            var props = {};
            function rec(o) { if (o && o.name !== undefined) props[o.name] = o.value; return b; }
            var b = {
                addSlider: rec, addCheckbox: rec, addText: rec, addColor: rec,
                addCombo: function(o){ if(o&&o.name!==undefined) props[o.name]=(o.value!==undefined?o.value:(o.options&&o.options[0]?o.options[0].value:0)); return b; },
                finish: function(){ return props; }
            };
            return b;
        }
        var engine = {
            AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
            registerAudioBuffers: function(){ return { average: function(){ return 0; }, length: 0 }; },
            getArrayValues: function(){ return []; }
        };
        """
        context.evaluateScript(prelude)
        // WE scripts use ES `export`; JSContext evaluates a plain script, so drop the `export ` keyword and
        // read the resulting globals. (A module loader would be heavier and isn't needed for these.)
        let stripped = script.replacingOccurrences(of: "export ", with: "")
        context.evaluateScript(stripped)

        if let props = context.objectForKeyedSubscript("scriptProperties"), !props.isUndefined,
           let dict = props.toDictionary() as? [String: Any] {
            properties = dict
        }
        guard let update = context.objectForKeyedSubscript("update"), update.isObject else { return nil }
        updateFn = update
        if let initFn = context.objectForKeyedSubscript("init"), initFn.isObject { hasInit = true; _ = initFn.call(withArguments: []) }
        loaded = true
    }

    /// Run `update(value)` and return its result as a string (clocks/text), or nil on any error/non-string.
    public func updateString(_ value: String = "") -> String? {
        guard loaded, let result = updateFn?.call(withArguments: [value]), !result.isUndefined, !result.isNull
        else { return nil }
        return result.isString ? result.toString() : nil
    }

    /// Run `update(value)` and return its result as a number, or nil on any error/non-number.
    public func updateNumber(_ value: Double = 0) -> Double? {
        guard loaded, let result = updateFn?.call(withArguments: [value]), !result.isUndefined, !result.isNull,
              result.isNumber else { return nil }
        return result.toDouble()
    }
}

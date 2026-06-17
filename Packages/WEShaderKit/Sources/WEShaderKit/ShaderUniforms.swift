// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Extracts a WE shader's `uniform <type> g_Name; // {json}` declarations and
// their JSON annotations (the property/material metadata) — the data behind a per-wallpaper property
// panel, and later the transpiler's uniform layout. Dialect from the shader bytes + public WE docs.
import Foundation

/// One `uniform g_*` declaration from a WE shader, with its annotation metadata if present.
public struct ShaderUniform: Sendable, Equatable {
    public let type: String            // float, sampler2D, vec4, mat4, …
    public let name: String            // g_Threshold
    public let material: String?       // UI label key from the annotation
    public let defaultValue: String?   // default as a string (number, asset path, or vector)
    public let range: [Double]?        // [min, max] from the annotation
    public let arrayCount: Int?        // N for `uniform float g_Name[N];` (e.g. audio spectra), else nil

    public init(type: String, name: String, material: String? = nil,
                defaultValue: String? = nil, range: [Double]? = nil, arrayCount: Int? = nil) {
        self.type = type
        self.name = name
        self.material = material
        self.defaultValue = defaultValue
        self.range = range
        self.arrayCount = arrayCount
    }
}

/// Pulls the `uniform g_*` declarations (and their JSON annotations) out of a WE shader.
public enum ShaderUniforms {
    // uniform <type> <name>[optional array size] ; // optional {json annotation}
    // Names are usually g_* (engine globals) but materials also declare u_* user uniforms; capture both.
    // The array size (group 3) is captured so `uniform float g_AudioSpectrum16Left[16];` round-trips as a
    // float[16] member rather than a scalar (which makes `g_…[i]` indexing invalid MSL).
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*uniform\s+(\w+)\s+(\w+)\s*(?:\[\s*(\d+)\s*\])?\s*;?\s*(?://\s*(\{.*\}))?"#)

    /// Every `uniform` declaration in `source`, in declaration order.
    public static func parse(_ source: String) -> [ShaderUniform] {
        var uniforms: [ShaderUniform] = []
        source.enumerateLines { line, _ in
            let whole = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: whole),
                  let typeRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line) else { return }
            var material: String?
            var defaultValue: String?
            var range: [Double]?
            var arrayCount: Int?
            if let arrayRange = Range(match.range(at: 3), in: line) { arrayCount = Int(line[arrayRange]) }
            if let jsonRange = Range(match.range(at: 4), in: line),
               let json = (try? JSONSerialization.jsonObject(with: Data(line[jsonRange].utf8))) as? [String: Any] {
                material = json["material"] as? String
                defaultValue = stringify(json["default"])
                if let raw = json["range"] as? [Any] {
                    range = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
                }
            }
            uniforms.append(ShaderUniform(type: String(line[typeRange]), name: String(line[nameRange]),
                                          material: material, defaultValue: defaultValue, range: range,
                                          arrayCount: arrayCount))
        }
        return uniforms
    }

    /// A default value (number, asset path string, or numeric vector) as a string.
    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return trimmed(number.doubleValue)
        case let array as [Any]:
            return array.compactMap { ($0 as? NSNumber).map { trimmed($0.doubleValue) } }.joined(separator: " ")
        default: return nil
        }
    }

    private static func trimmed(_ value: Double) -> String {
        // `Int(value)` traps on a value past Int.max or a non-finite one; an untrusted .pkg can put either
        // in a uniform's JSON default (e.g. `"default":1e20`). Only take the integer spelling when it fits.
        if value == value.rounded(), let exact = Int(exactly: value) { return String(exact) }
        return String(value)
    }
}

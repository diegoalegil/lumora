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

    public init(type: String, name: String, material: String? = nil,
                defaultValue: String? = nil, range: [Double]? = nil) {
        self.type = type
        self.name = name
        self.material = material
        self.defaultValue = defaultValue
        self.range = range
    }
}

/// Pulls the `uniform g_*` declarations (and their JSON annotations) out of a WE shader.
public enum ShaderUniforms {
    // uniform <type> g_<name>[optional array] ; // optional {json annotation}
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*uniform\s+(\w+)\s+(g_\w+)\s*(?:\[\s*\d+\s*\])?\s*;?\s*(?://\s*(\{.*\}))?"#)

    /// Every `uniform g_*` declaration in `source`, in declaration order.
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
            if let jsonRange = Range(match.range(at: 3), in: line),
               let json = (try? JSONSerialization.jsonObject(with: Data(line[jsonRange].utf8))) as? [String: Any] {
                material = json["material"] as? String
                defaultValue = stringify(json["default"])
                if let raw = json["range"] as? [Any] {
                    range = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
                }
            }
            uniforms.append(ShaderUniform(type: String(line[typeRange]), name: String(line[nameRange]),
                                          material: material, defaultValue: defaultValue, range: range))
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
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

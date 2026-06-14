// SPDX-License-Identifier: MIT
// Provenance: clean-room. WE scene fields are polymorphic: a value can be a plain literal
// OR an object {"script": "...", "value": ...}. This wrapper decodes both uniformly.
import Foundation

/// A scene field that may be a plain value or a scripted `{ "script": …, "value": … }` object.
/// The static `value` is always available; `script` (if present) is the SceneScript expression
/// that drives the field at runtime (executed later by WESceneDynamics).
public struct Animatable<Value: Sendable & Decodable & Equatable>: Sendable, Equatable, Decodable {
    public let value: Value
    public let script: String?

    public init(value: Value, script: String? = nil) {
        self.value = value
        self.script = script
    }

    enum CodingKeys: String, CodingKey { case value, script }

    public init(from decoder: any Decoder) throws {
        // Object form: { "value": …, "script"?: … }
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.value) {
            self.value = try keyed.decode(Value.self, forKey: .value)
            self.script = try keyed.decodeIfPresent(String.self, forKey: .script)
            return
        }
        // Plain form: the literal value itself.
        let single = try decoder.singleValueContainer()
        self.value = try single.decode(Value.self)
        self.script = nil
    }

    /// True when this field is driven by a SceneScript expression.
    public var isScripted: Bool { script != nil }
}

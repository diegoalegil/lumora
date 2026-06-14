// SPDX-License-Identifier: MIT
// Provenance: clean-room. `general.properties` control types from docs.wallpaperengine.io
// and observed project.json files. Mirrors the user-facing settings WE exposes.
import Foundation

/// A single user-configurable property from `general.properties`.
public struct WEProperty: Sendable, Equatable, Decodable {
    public let order: Int?
    public let text: String?
    public let type: PropertyType
    public let value: PropertyValue
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let options: [PropertyOption]?

    enum CodingKeys: String, CodingKey {
        case order, text, type, value, min, max, step, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.value = try c.decodeIfPresent(PropertyValue.self, forKey: .value) ?? .null
        self.options = try c.decodeIfPresent([PropertyOption].self, forKey: .options)
        // WE files occasionally encode these numerics as strings ("min":"0"); decode leniently so
        // one stringly-typed field doesn't abort the whole manifest.
        self.order = Self.lenientInt(c, .order)
        self.min = Self.lenientDouble(c, .min)
        self.max = Self.lenientDouble(c, .max)
        self.step = Self.lenientDouble(c, .step)
        // `type` is sometimes absent; infer from value/shape when missing.
        if let raw = try c.decodeIfPresent(String.self, forKey: .type) {
            self.type = PropertyType(lenient: raw)
        } else {
            self.type = PropertyType.inferred(from: value, hasOptions: options != nil)
        }
    }

    private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Int(s) ?? Double(s).map { Int($0) }
        }
        return nil
    }

    private static func lenientDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Double(s)
        }
        return nil
    }

    public init(order: Int? = nil, text: String? = nil, type: PropertyType,
                value: PropertyValue, min: Double? = nil, max: Double? = nil,
                step: Double? = nil, options: [PropertyOption]? = nil) {
        self.order = order; self.text = text; self.type = type; self.value = value
        self.min = min; self.max = max; self.step = step; self.options = options
    }

    /// For `type == .color`, decode WE's `"R G B"` (0...1 floats) into components.
    public var colorComponents: (r: Double, g: Double, b: Double)? {
        guard type == .color, case let .string(s) = value else { return nil }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

public enum PropertyType: String, Sendable, Equatable {
    case color, slider, bool, combo, textinput, text, file

    init(lenient raw: String) {
        self = PropertyType(rawValue: raw.lowercased()) ?? .text
    }

    static func inferred(from value: PropertyValue, hasOptions: Bool) -> PropertyType {
        if hasOptions { return .combo }
        switch value {
        case .bool: return .bool
        case .number: return .slider
        case .string, .null: return .text
        }
    }
}

/// A polymorphic property value (`color`→string, `slider`→number, `bool`→bool, …).
public enum PropertyValue: Sendable, Equatable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .null
    }
}

public struct PropertyOption: Sendable, Equatable, Decodable {
    public let label: String?
    public let value: PropertyValue
}

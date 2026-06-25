// SPDX-License-Identifier: MIT
// Provenance: clean-room. Pure logic behind the per-wallpaper customization panel: turning a wallpaper's
// `general.properties` schema into an ordered list the UI renders, humanizing WE's HTML/loc-key labels,
// coercing edited values into range, and merging user overrides with defaults. No UI, no I/O — unit-tested.
import Foundation
import WECore

/// One row of a wallpaper's customization schema (a property plus its stable key). Identified by key so the
/// settings list can `ForEach` it.
public struct WallpaperPropertySchemaItem: Identifiable, Equatable, Sendable {
    public let key: String
    public let property: WEProperty
    public var id: String { key }
    public init(key: String, property: WEProperty) {
        self.key = key
        self.property = property
    }
    /// The label to show: WE's `text`, stripped of HTML and humanized, falling back to the key.
    public var label: String { WallpaperProperties.displayLabel(for: property, key: key) }
}

/// Pure helpers for the customization panel.
public enum WallpaperProperties {
    /// The ordered schema for a wallpaper's `general` section (the display order WE uses). Empty when there
    /// are no properties.
    public static func schema(from general: GeneralSection?) -> [WallpaperPropertySchemaItem] {
        guard let general else { return [] }
        return general.orderedProperties.map { WallpaperPropertySchemaItem(key: $0.key, property: $0.property) }
    }

    /// The default value WE ships for a property.
    public static func defaultValue(for property: WEProperty) -> PropertyValue { property.value }

    /// Clamp/validate an edited value into what the property allows: sliders are clamped to `[min, max]`;
    /// a combo value must be one of its options (otherwise the edit is rejected and the default kept);
    /// everything else passes through unchanged.
    public static func coerce(_ value: PropertyValue, for property: WEProperty) -> PropertyValue {
        switch property.type {
        case .slider:
            guard case let .number(n) = value else { return property.value }
            var clamped = n
            if let lo = property.min { clamped = Swift.max(lo, clamped) }
            if let hi = property.max { clamped = Swift.min(hi, clamped) }
            return .number(clamped)
        case .combo:
            let allowed = property.options?.map(\.value) ?? []
            return allowed.contains(value) ? value : property.value
        case .bool:
            if case .bool = value { return value }
            return property.value
        case .color, .textinput:
            if case .string = value { return value }
            return property.value
        default:
            return property.value   // display-only / unsupported types aren't edited
        }
    }

    /// The effective value for every editable property: the user's (coerced) override when present, else the
    /// default. Display-only rows (group/text) are skipped.
    public static func effectiveValues(schema: [WallpaperPropertySchemaItem],
                                       overrides: [String: PropertyValue]) -> [String: PropertyValue] {
        var result: [String: PropertyValue] = [:]
        for item in schema where item.property.type.isEditable {
            if let override = overrides[item.key] {
                result[item.key] = coerce(override, for: item.property)
            } else {
                result[item.key] = item.property.value
            }
        }
        return result
    }

    /// Drop overrides that equal the default (or aren't valid editable keys), so only genuine customizations
    /// are stored. Keeps the on-disk store small and makes "is modified" trivial.
    public static func prunedOverrides(schema: [WallpaperPropertySchemaItem],
                                       overrides: [String: PropertyValue]) -> [String: PropertyValue] {
        let editable = Dictionary(uniqueKeysWithValues: schema.filter { $0.property.type.isEditable }
            .map { ($0.key, $0.property) })
        var result: [String: PropertyValue] = [:]
        for (key, raw) in overrides {
            guard let property = editable[key] else { continue }
            let coerced = coerce(raw, for: property)
            if coerced != property.value { result[key] = coerced }
        }
        return result
    }

    /// Whether the wallpaper has any genuine customization stored.
    public static func isModified(schema: [WallpaperPropertySchemaItem],
                                  overrides: [String: PropertyValue]) -> Bool {
        !prunedOverrides(schema: schema, overrides: overrides).isEmpty
    }

    /// How many editable controls the schema exposes (for the "Customize (N)" header).
    public static func editableCount(_ schema: [WallpaperPropertySchemaItem]) -> Int {
        schema.filter { $0.property.type.isEditable }.count
    }

    // MARK: Label humanization

    /// A readable label for a property: WE's `text` with its HTML stripped; if that looks like a localization
    /// key (e.g. `ui_browse_properties_scheme_color`) it's expanded; if blank, the key is humanized.
    public static func displayLabel(for property: WEProperty, key: String) -> String {
        let stripped = stripHTML(property.text ?? "")
        if stripped.isEmpty { return humanize(key) }
        if looksLikeLocKey(stripped) { return humanizeLocKey(stripped) }
        return stripped
    }

    /// Remove HTML tags (turning `<br>` into a space) and collapse whitespace — WE labels are sprinkled with
    /// `<b>`, `<br/>`, `<small>` and the like.
    public static func stripHTML(_ raw: String) -> String {
        var out = ""
        var inTag = false
        for ch in raw {
            if ch == "<" { inTag = true; out += " "; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        // Decode the handful of entities WE uses, then collapse runs of whitespace.
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
                 .replacingOccurrences(of: "&amp;", with: "&")
                 .replacingOccurrences(of: "&lt;", with: "<")
                 .replacingOccurrences(of: "&gt;", with: ">")
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                  .joined(separator: " ")
                  .trimmingCharacters(in: .whitespaces)
    }

    /// A loc key is all-lowercase, has no spaces and uses underscores (e.g. `ui_browse_properties_opacity`).
    private static func looksLikeLocKey(_ s: String) -> Bool {
        guard !s.contains(" "), s.contains("_") else { return false }
        return s == s.lowercased() && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Turn a loc key into a phrase: strip a known prefix, split on `_`, sentence-case.
    private static func humanizeLocKey(_ s: String) -> String {
        var key = s
        for prefix in ["ui_browse_properties_", "ui_browse_property_", "ui_properties_", "ui_"] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count); break
        }
        return sentenceCase(key.split(separator: "_").map(String.init))
    }

    /// Humanize a smashed key as best we can: split on underscores/camelCase, sentence-case.
    private static func humanize(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch == "_" || ch == "-" { if !current.isEmpty { words.append(current); current = "" } }
            else if ch.isUppercase, !current.isEmpty { words.append(current); current = String(ch) }
            else { current.append(ch) }
        }
        if !current.isEmpty { words.append(current) }
        return words.isEmpty ? key : sentenceCase(words)
    }

    private static func sentenceCase(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }
}

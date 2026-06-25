// SPDX-License-Identifier: MIT
// Provenance: clean-room. Observable state for one wallpaper's customization panel: its ordered schema plus
// the live (coerced, pruned) overrides. Editing a value clamps/validates it via `WallpaperProperties` and
// publishes the pruned override map through `onChange` so the host persists it. Logic is unit-tested.
import Foundation
import Observation
import WECore

@Observable
public final class WallpaperPropertiesModel {
    public let wallpaperID: String
    public let schema: [WallpaperPropertySchemaItem]
    /// Only the genuine, default-differing overrides (kept pruned at all times).
    public private(set) var overrides: [String: PropertyValue]

    /// Fires with the pruned override map whenever a value changes, so the host writes it to the store.
    @ObservationIgnored public var onChange: (([String: PropertyValue]) -> Void)?

    public init(wallpaperID: String, schema: [WallpaperPropertySchemaItem],
                overrides: [String: PropertyValue] = [:], onChange: (([String: PropertyValue]) -> Void)? = nil) {
        self.wallpaperID = wallpaperID
        self.schema = schema
        self.overrides = WallpaperProperties.prunedOverrides(schema: schema, overrides: overrides)
        self.onChange = onChange
    }

    /// The effective value for an editable property (override if any, else default).
    public func value(for key: String) -> PropertyValue {
        guard let item = schema.first(where: { $0.key == key }) else { return .null }
        if let override = overrides[key] { return WallpaperProperties.coerce(override, for: item.property) }
        return item.property.value
    }

    /// Edit a property's value: coerce it, store it only if it differs from the default, publish the result.
    public func set(_ value: PropertyValue, for key: String) {
        guard let item = schema.first(where: { $0.key == key }), item.property.type.isEditable else { return }
        let coerced = WallpaperProperties.coerce(value, for: item.property)
        var next = overrides
        if coerced == item.property.value { next.removeValue(forKey: key) } else { next[key] = coerced }
        guard next != overrides else { return }
        overrides = next
        onChange?(next)
    }

    /// True when this wallpaper has any customization.
    public var isModified: Bool { !overrides.isEmpty }

    /// Number of editable controls (for the panel header).
    public var editableCount: Int { WallpaperProperties.editableCount(schema) }

    /// Restore every property to its WE default.
    public func reset() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        onChange?([:])
    }
}

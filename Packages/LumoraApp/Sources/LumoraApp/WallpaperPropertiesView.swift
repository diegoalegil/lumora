// SPDX-License-Identifier: MIT
// Provenance: clean-room (SwiftUI per Apple docs). Renders a wallpaper's `general.properties` as live controls
// (slider, colour, toggle, combo, text), grouped by the section headers WE ships. Binds to the unit-tested
// `WallpaperPropertiesModel`, which clamps/validates every edit and persists it. Presentation only.
import SwiftUI
import WECore
import WallpaperShell

/// Parse/format WE's `"r g b"` (0…1 floats, optional alpha) ↔ SwiftUI `Color`.
enum WEColor {
    static func color(from value: PropertyValue) -> Color {
        guard case let .string(s) = value else { return .gray }
        let p = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
        guard p.count >= 3 else { return .gray }
        return Color(.sRGB, red: p[0], green: p[1], blue: p[2], opacity: p.count >= 4 ? p[3] : 1)
    }

    static func string(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        return "\(trim(r)) \(trim(g)) \(trim(b))"
    }

    private static func trim(_ v: Double) -> String {
        // Keep WE's compact float form: drop trailing zeros, clamp to [0,1].
        let clamped = Swift.min(1, Swift.max(0, v))
        return String(format: "%g", (clamped * 1_000_000).rounded() / 1_000_000)
    }
}

/// The list of customization controls for one wallpaper.
struct WallpaperPropertiesView: View {
    @Bindable var model: WallpaperPropertiesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.schema) { item in
                row(for: item)
            }
        }
    }

    @ViewBuilder
    private func row(for item: WallpaperPropertySchemaItem) -> some View {
        switch item.property.type {
        case .group:
            Text(item.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        case .text:
            Text(item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .slider:
            sliderRow(item)
        case .color:
            ColorPicker(item.label, selection: colorBinding(item.key))
                .font(.callout)
        case .bool:
            Toggle(item.label, isOn: boolBinding(item.key))
                .font(.callout)
        case .combo:
            comboRow(item)
        case .textinput:
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).font(.caption).foregroundStyle(.secondary)
                TextField("", text: stringBinding(item.key)).textFieldStyle(.roundedBorder)
            }
        case .scenetexture, .file, .usershortcut:
            HStack {
                Text(item.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Set in Wallpaper Engine").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func sliderRow(_ item: WallpaperPropertySchemaItem) -> some View {
        // Sanitized, finite, ascending bounds shared with the model's clamp — a raw manifest min/max can be
        // non-finite (e.g. "1e400" → ∞) or inverted, which would make the Slider's range undefined.
        let bounds = WallpaperProperties.sliderBounds(for: item.property)
        let lo = bounds.lo, hi = bounds.hi
        let step = bounds.step ?? 0
        let current = { if case let .number(n) = model.value(for: item.key) { return n } else { return lo } }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.label).font(.callout).lineLimit(1)
                Spacer()
                Text(String(format: abs(current) >= 10 ? "%.0f" : "%.2f", current))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if step > 0 {
                Slider(value: doubleBinding(item.key, fallback: lo), in: lo...hi, step: step)
            } else {
                Slider(value: doubleBinding(item.key, fallback: lo), in: lo...hi)
            }
        }
    }

    private func comboRow(_ item: WallpaperPropertySchemaItem) -> some View {
        let options = item.property.options ?? []
        return Picker(item.label, selection: comboBinding(item.key, options: options)) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i].label ?? optionText(options[i].value)).tag(i)
            }
        }
        .font(.callout)
    }

    // MARK: Bindings

    private func doubleBinding(_ key: String, fallback: Double) -> Binding<Double> {
        Binding(get: {
            if case let .number(n) = model.value(for: key) { return n } else { return fallback }
        }, set: { model.set(.number($0), for: key) })
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: {
            if case let .bool(b) = model.value(for: key) { return b } else { return false }
        }, set: { model.set(.bool($0), for: key) })
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: {
            if case let .string(s) = model.value(for: key) { return s } else { return "" }
        }, set: { model.set(.string($0), for: key) })
    }

    private func colorBinding(_ key: String) -> Binding<Color> {
        Binding(get: { WEColor.color(from: model.value(for: key)) },
                set: { model.set(.string(WEColor.string(from: $0)), for: key) })
    }

    private func comboBinding(_ key: String, options: [PropertyOption]) -> Binding<Int> {
        Binding(get: {
            let current = model.value(for: key)
            return options.firstIndex { $0.value == current } ?? 0
        }, set: { i in
            guard options.indices.contains(i) else { return }
            model.set(options[i].value, for: key)
        })
    }

    private func optionText(_ value: PropertyValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return String(format: "%g", n)
        case .bool(let b):   return b ? "On" : "Off"
        case .null:          return "—"
        }
    }
}

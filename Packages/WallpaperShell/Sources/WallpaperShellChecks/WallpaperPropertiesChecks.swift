// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of the per-wallpaper customization logic, model and store.
import Foundation
import WECore
import WallpaperShell

private func slider(_ value: Double, min: Double, max: Double, text: String? = nil) -> WEProperty {
    WEProperty(text: text, type: .slider, value: .number(value), min: min, max: max)
}
private func combo(_ value: String, _ options: [String]) -> WEProperty {
    WEProperty(type: .combo, value: .string(value), options: options.map { PropertyOption(label: $0, value: .string($0)) })
}
private func item(_ key: String, _ p: WEProperty) -> WallpaperPropertySchemaItem {
    WallpaperPropertySchemaItem(key: key, property: p)
}

func runWallpaperPropertiesChecks() {
    Check.section("WallpaperProperties.stripHTML / labels")

    Check.that("strips simple tags", WallpaperProperties.stripHTML("<b>Opacity</b>") == "Opacity")
    Check.that("turns <br/> into a space", WallpaperProperties.stripHTML("Text 2 Color<br/>Color") == "Text 2 Color Color")
    Check.that("collapses whitespace", WallpaperProperties.stripHTML("  a   b\t c ") == "a b c")
    Check.that("decodes &amp;", WallpaperProperties.stripHTML("Cats &amp; Dogs") == "Cats & Dogs")

    let locProp = WEProperty(text: "ui_browse_properties_scheme_color", type: .color, value: .string("1 1 1"))
    Check.that("expands a loc key", WallpaperProperties.displayLabel(for: locProp, key: "schemecolor") == "Scheme color")

    let htmlProp = WEProperty(text: "<b>Opacity</b>", type: .slider, value: .number(1))
    Check.that("uses a stripped html label", WallpaperProperties.displayLabel(for: htmlProp, key: "appdockalpha") == "Opacity")

    let blankProp = WEProperty(text: nil, type: .bool, value: .bool(true))
    Check.that("falls back to a humanized key", WallpaperProperties.displayLabel(for: blankProp, key: "use_24_hour") == "Use 24 hour")

    Check.section("WallpaperProperties.coerce")

    let sl = slider(20, min: 0, max: 60)
    Check.that("slider clamps above max", WallpaperProperties.coerce(.number(100), for: sl) == .number(60))
    Check.that("slider clamps below min", WallpaperProperties.coerce(.number(-5), for: sl) == .number(0))
    Check.that("slider keeps an in-range value", WallpaperProperties.coerce(.number(30), for: sl) == .number(30))
    Check.that("slider rejects a non-number", WallpaperProperties.coerce(.string("x"), for: sl) == .number(20))

    let cb = combo("a", ["a", "b", "c"])
    Check.that("combo accepts a listed option", WallpaperProperties.coerce(.string("b"), for: cb) == .string("b"))
    Check.that("combo rejects an unlisted option", WallpaperProperties.coerce(.string("z"), for: cb) == .string("a"))

    Check.section("WallpaperProperties.effective / pruned")

    let schema = [
        item("op", slider(20, min: 0, max: 60)),
        item("mode", combo("a", ["a", "b"])),
        item("on", WEProperty(type: .bool, value: .bool(false))),
        item("hdr", WEProperty(type: .group, value: .null)),        // display-only
        item("note", WEProperty(type: .text, value: .string("hi"))), // display-only
    ]
    Check.that("editable count ignores group/text", WallpaperProperties.editableCount(schema) == 3)

    let eff = WallpaperProperties.effectiveValues(schema: schema, overrides: ["op": .number(45)])
    Check.that("effective uses the override", eff["op"] == .number(45))
    Check.that("effective uses defaults elsewhere", eff["mode"] == .string("a") && eff["on"] == .bool(false))
    Check.that("effective omits display-only rows", eff["hdr"] == nil && eff["note"] == nil)

    let pruned = WallpaperProperties.prunedOverrides(schema: schema,
        overrides: ["op": .number(20), "mode": .string("b"), "ghost": .number(1)])
    Check.that("prune drops a default-valued override", pruned["op"] == nil)
    Check.that("prune keeps a real change", pruned["mode"] == .string("b"))
    Check.that("prune drops an unknown key", pruned["ghost"] == nil)
    Check.that("isModified reflects pruning",
               !WallpaperProperties.isModified(schema: schema, overrides: ["op": .number(20)]) &&
                WallpaperProperties.isModified(schema: schema, overrides: ["mode": .string("b")]))

    Check.section("WallpaperPropertiesModel")

    var published: [String: PropertyValue]? = nil
    let model = WallpaperPropertiesModel(wallpaperID: "w1", schema: schema, overrides: [:]) { published = $0 }
    Check.that("starts unmodified", !model.isModified)
    Check.that("reads defaults", model.value(for: "op") == .number(20) && model.value(for: "mode") == .string("a"))

    model.set(.number(200), for: "op")   // clamps to 60
    Check.that("set clamps the value", model.value(for: "op") == .number(60))
    Check.that("set publishes the pruned override", published?["op"] == .number(60))
    Check.that("now modified", model.isModified)

    model.set(.number(20), for: "op")    // back to default -> override removed
    Check.that("returning to default clears the override", model.value(for: "op") == .number(20) && !model.isModified)

    model.set(.bool(true), for: "on")
    Check.that("editing a bool works", model.value(for: "on") == .bool(true))
    model.set(.string("x"), for: "hdr")   // display-only -> ignored
    Check.that("display-only edits are ignored", model.value(for: "hdr") == .null && model.editableCount == 3)

    model.reset()
    Check.that("reset clears everything", !model.isModified && model.value(for: "on") == .bool(false))
    Check.that("reset publishes empty", published?.isEmpty == true)

    Check.section("WallpaperPropertyStore")

    let repo = InMemoryWallpaperPropertyRepository()
    let store = WallpaperPropertyStore(repository: repo)
    Check.that("starts empty", store.overrides(for: "w1").isEmpty)
    store.setOverrides(["mode": .string("b")], for: "w1")
    Check.that("stores overrides", store.overrides(for: "w1") == ["mode": .string("b")])
    Check.that("empty overrides remove the record", { store.setOverrides([:], for: "w1"); return store.all["w1"] == nil }())

    // JSON round-trip: a value persisted and reloaded comes back identical.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumora-proptest-\(abs(schema.count))")
    let json = JSONWallpaperPropertyRepository(fileURL: dir.appendingPathComponent("p.json"))
    try? json.save(["w2": ["op": .number(33), "on": .bool(true)]])
    let reloaded = JSONWallpaperPropertyRepository(fileURL: dir.appendingPathComponent("p.json")).load()
    Check.that("JSON round-trips overrides", reloaded["w2"]?["op"] == .number(33) && reloaded["w2"]?["on"] == .bool(true))
}

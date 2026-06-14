// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of WECore contracts (CLT-only equivalent of unit tests).
import Foundation
import WECore

func decodeProperty(_ json: String) throws -> WEProperty {
    try JSONDecoder().decode(WEProperty.self, from: Data(json.utf8))
}

struct Holder<T: Sendable & Decodable & Equatable>: Decodable { let field: Animatable<T> }
func decodeAnimatable<T>(_ json: String, _ : T.Type) throws -> Animatable<T> {
    try JSONDecoder().decode(Holder<T>.self, from: Data(json.utf8)).field
}

// MARK: Manifest decoding
Check.section("Manifest decoding")
if let m = Check.noThrow("decode web manifest", {
    try ProjectManifest.decode(from: Data(#"""
    {"title":"FGO 师匠","type":"web","file":"index.html","preview":"preview.jpg",
     "tags":["Anime"],"visibility":"public","workshopid":861750235,
     "general":{"properties":{
       "schemecolor":{"order":0,"text":"ui_color","type":"color","value":"0.56 0.31 0.58"},
       "customint":{"max":60,"min":0,"text":"User slider","type":"slider","value":20}}}}
    """#.utf8))
}) {
    Check.that("web type", m.type == .web)
    Check.that("web file", m.file == "index.html")
    Check.that("web title", m.title == "FGO 师匠")
    Check.that("web tags", m.tags == ["Anime"])
    Check.that("workshopid int -> string", m.workshopID == "861750235")
    Check.that("property count", m.general?.properties.count == 2)
}

if let v = Check.noThrow("decode video manifest", {
    try ProjectManifest.decode(from: Data(#"{"type":"video","file":"bg.mp4"}"#.utf8))
}) {
    Check.that("video type", v.type == .video)
    Check.that("video file", v.file == "bg.mp4")
}
if let s = Check.noThrow("decode scene manifest", {
    try ProjectManifest.decode(from: Data(#"{"type":"scene","file":"scene.pkg"}"#.utf8))
}) {
    Check.that("scene type", s.type == .scene)
}

if let app = Check.noThrow("decode application manifest (rawType kept)", {
    try ProjectManifest.decode(from: Data(#"{"type":"application","file":"a.exe"}"#.utf8))
}) {
    Check.that("application rawType preserved", app.rawType == "application")
    Check.that("application parsed type is nil", app.type == nil)
}

Check.throwsError("parse(application) rejected", { try WallpaperType.parse("application") },
                  satisfies: { ($0 as? WallpaperTypeError) == .unsupportedApplication })
Check.throwsError("parse(unknown) rejected", { try WallpaperType.parse("hologram") },
                  satisfies: { ($0 as? WallpaperTypeError) == .unknown("hologram") })

if let i = Check.noThrow("workshopid as int", {
    try ProjectManifest.decode(from: Data(#"{"type":"video","file":"a.mp4","workshopid":123}"#.utf8))
}) { Check.that("int workshopid", i.workshopID == "123") }
if let st = Check.noThrow("workshopid as string", {
    try ProjectManifest.decode(from: Data(#"{"type":"video","file":"a.mp4","workshopid":"456"}"#.utf8))
}) { Check.that("string workshopid", st.workshopID == "456") }

if let ord = Check.noThrow("decode ordered properties", {
    try ProjectManifest.decode(from: Data(#"""
    {"type":"scene","file":"scene.pkg","general":{"properties":{
      "b":{"order":2,"type":"bool","value":true},
      "a":{"order":1,"type":"slider","value":5}}}}
    """#.utf8))
}) {
    Check.that("ordered by order field", ord.general?.orderedProperties.map(\.key) == ["a", "b"])
}

// MARK: Properties
Check.section("Property decoding")
if let c = Check.noThrow("decode color", { try decodeProperty(#"{"type":"color","value":"0.56 0.31 0.58"}"#) }) {
    Check.that("color type", c.type == .color)
    if let comp = c.colorComponents {
        Check.that("color r", abs(comp.r - 0.56) < 1e-6)
        Check.that("color g", abs(comp.g - 0.31) < 1e-6)
        Check.that("color b", abs(comp.b - 0.58) < 1e-6)
    } else { Check.that("color components parsed", false) }
}
if let sl = Check.noThrow("decode slider", { try decodeProperty(#"{"type":"slider","value":20,"min":0,"max":60,"step":1}"#) }) {
    Check.that("slider value", sl.value == .number(20))
    Check.that("slider min", sl.min == 0)
    Check.that("slider max", sl.max == 60)
}
if let b = Check.noThrow("decode bool", { try decodeProperty(#"{"type":"bool","value":true}"#) }) {
    Check.that("bool value", b.value == .bool(true))
}
if let combo = Check.noThrow("decode combo", {
    try decodeProperty(#"{"type":"combo","value":"hi","options":[{"label":"High","value":"hi"},{"label":"Low","value":"lo"}]}"#)
}) {
    Check.that("combo options", combo.options?.count == 2)
    Check.that("combo first option value", combo.options?.first?.value == .string("hi"))
}
if let file = Check.noThrow("decode file", { try decodeProperty(#"{"type":"file","value":null}"#) }) {
    Check.that("file value null", file.value == .null)
}
if let inf = Check.noThrow("infer bool type when missing", { try decodeProperty(#"{"value":false}"#) }) {
    Check.that("inferred bool", inf.type == .bool)
}
if let one = Check.noThrow("integer 1 not misread as bool", { try decodeProperty(#"{"type":"slider","value":1}"#) }) {
    Check.that("integer stays number", one.value == .number(1))
}
if let strnum = Check.noThrow("lenient string-encoded slider range", { try decodeProperty(#"{"type":"slider","value":20,"min":"0","max":"60","order":"3"}"#) }) {
    Check.that("string min parsed", strnum.min == 0)
    Check.that("string max parsed", strnum.max == 60)
    Check.that("string order parsed", strnum.order == 3)
}
if let mixed = Check.noThrow("string-encoded numeric does not abort manifest", {
    try ProjectManifest.decode(from: Data(#"{"type":"scene","file":"scene.pkg","general":{"properties":{"s":{"type":"slider","value":5,"min":"0"}}}}"#.utf8))
}) {
    Check.that("manifest decoded despite string min", mixed.general?.properties["s"]?.min == 0)
}

// MARK: Animatable
Check.section("Animatable polymorphic decoding")
if let plain = Check.noThrow("plain string value", { try decodeAnimatable(#"{"field":"1 2 0"}"#, String.self) }) {
    Check.that("plain value", plain.value == "1 2 0")
    Check.that("plain not scripted", !plain.isScripted)
}
if let scripted = Check.noThrow("scripted object", { try decodeAnimatable(#"{"field":{"script":"audio()","value":"0 0 0"}}"#, String.self) }) {
    Check.that("scripted value", scripted.value == "0 0 0")
    Check.that("scripted script", scripted.script == "audio()")
    Check.that("scripted flag", scripted.isScripted)
}
if let obj = Check.noThrow("scene object scripted transform", {
    try JSONDecoder().decode(SceneObject.self, from: Data(#"""
    {"name":"layer1","image":"m.json","origin":{"script":"parallax()","value":"960 540 0"},"scale":"1 1 1","visible":true}
    """#.utf8))
}) {
    Check.that("object name", obj.name == "layer1")
    Check.that("origin script", obj.origin?.script == "parallax()")
    Check.that("origin value", obj.origin?.value == "960 540 0")
    Check.that("scale not scripted", obj.scale?.isScripted == false)
    Check.that("visible", obj.visible?.value == true)
}

// MARK: Router
Check.section("WallpaperRouter")
let router = WallpaperRouter()
let folder = URL(fileURLWithPath: "/tmp/workshop/861750235", isDirectory: true)
let videoManifest = ProjectManifest(title: "x", rawType: "video", file: "bg.mp4", workshopID: "861750235")
if let resolved = Check.noThrow("resolve video", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: videoManifest), manifest: videoManifest)
}) {
    Check.that("resolved type", resolved.type == .video)
    Check.that("resolved main file", resolved.mainFileURL == folder.appendingPathComponent("bg.mp4"))
    Check.that("resolved id", resolved.ref.id == "861750235")
}
let appManifest = ProjectManifest(title: "x", rawType: "application", file: "a.exe")
Check.throwsError("router rejects application", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: appManifest), manifest: appManifest)
}, satisfies: { ($0 as? WallpaperTypeError) == .unsupportedApplication })
let emptyFileManifest = ProjectManifest(title: "x", rawType: "scene", file: "")
Check.throwsError("router rejects missing main file", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: emptyFileManifest), manifest: emptyFileManifest)
}, satisfies: { ($0 as? RoutingError) == .missingMainFile(type: .scene) })

// MARK: FrameUniforms
Check.section("FrameUniforms")
let fu = FrameUniforms.zeroed(screenSize: SIMD2<Float>(1920, 1080))
Check.that("texel size derived", abs(fu.texelSize.x - 1.0/1920.0) < 1e-9)
Check.that("audio16 len", fu.audioSpectrumLeft16.count == 16)
Check.that("audio64 len", fu.audioSpectrumRight64.count == 64)

Check.summarize()

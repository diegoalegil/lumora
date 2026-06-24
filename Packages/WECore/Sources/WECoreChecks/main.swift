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
// A malformed workshopid type (bool/float/over-Int.max) must NOT sink an otherwise-valid manifest — it's an
// optional, non-load-bearing field, so it should decode to nil and the wallpaper still loads.
if let bad = Check.noThrow("a malformed workshopid doesn't reject the manifest", {
    try ProjectManifest.decode(from: Data(#"{"type":"scene","file":"scene.pkg","workshopid":true}"#.utf8))
}) { Check.that("a malformed workshopid decodes to nil", bad.workshopID == nil && bad.file == "scene.pkg") }

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
if let big = Check.noThrow("out-of-range string order does not crash", {
    try decodeProperty(#"{"type":"slider","value":1,"order":"1e30"}"#)
}) {
    Check.that("out-of-range order dropped to nil", big.order == nil)
}
if let frac = Check.noThrow("fractional string order rounds", { try decodeProperty(#"{"type":"slider","value":1,"order":"2.9"}"#) }) {
    Check.that("fractional order rounded", frac.order == 3)
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
// Untrusted Workshop manifests must not reach outside their own folder (path traversal).
let escapeManifest = ProjectManifest(title: "x", rawType: "video", file: "../../../../etc/passwd")
Check.throwsError("router rejects path traversal", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: escapeManifest), manifest: escapeManifest)
}, satisfies: { ($0 as? RoutingError) == .unsafeMainFile(file: "../../../../etc/passwd") })
let siblingManifest = ProjectManifest(title: "x", rawType: "video", file: "../861750235-evil/bg.mp4")
Check.throwsError("router rejects prefix-sibling escape", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: siblingManifest), manifest: siblingManifest)
}, satisfies: { $0 is RoutingError })
let nestedManifest = ProjectManifest(title: "x", rawType: "video", file: "assets/bg.mp4")
if let nested = Check.noThrow("router allows nested in-folder asset", {
    try router.resolve(ref: WallpaperRef(folderURL: folder, manifest: nestedManifest), manifest: nestedManifest)
}) {
    Check.that("nested asset resolved", nested.mainFileURL == folder.appendingPathComponent("assets/bg.mp4"))
}

// MARK: FrameUniforms
Check.section("FrameUniforms")
let fu = FrameUniforms.zeroed(screenSize: SIMD2<Float>(1920, 1080))
Check.that("texel size derived", abs(fu.texelSize.x - 1.0/1920.0) < 1e-9)
Check.that("audio16 len", fu.audioSpectrumLeft16.count == 16)
Check.that("audio64 len", fu.audioSpectrumRight64.count == 64)

// MARK: Playlist model
Check.section("Playlist model")
let refs = [WallpaperReference(id: "a"), WallpaperReference(id: "b"), WallpaperReference(id: "c"), WallpaperReference(id: "d")]
let pl = Playlist(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, name: "Anime",
                  items: refs, mode: .inOrder, rotationInterval: 300, transition: .init(kind: .crossfade, duration: 1.5))
if let data = Check.noThrow("playlist encodes", { try JSONEncoder().encode(pl) }),
   let back = Check.noThrow("playlist decodes", { try JSONDecoder().decode(Playlist.self, from: data) }) {
    Check.that("playlist round-trips identically", back == pl)
    Check.that("display target defaults to all", back.displayTarget == .all)
}
// resolvedOrder: in-order keeps the stored order; shuffle is a deterministic permutation of it.
Check.that("inOrder keeps the stored order", pl.resolvedOrder(seed: 1) == refs)
let shuffledPl = Playlist(name: "S", items: refs, mode: .shuffle)
Check.that("shuffle is deterministic for a given seed", shuffledPl.resolvedOrder(seed: 42) == shuffledPl.resolvedOrder(seed: 42))
Check.that("shuffle permutes (same multiset)", Set(shuffledPl.resolvedOrder(seed: 42)) == Set(refs))
Check.that("a different seed can give a different order",
           shuffledPl.resolvedOrder(seed: 1) != shuffledPl.resolvedOrder(seed: 999_999) || refs.count <= 1)
// Robustness: a corrupt/hand-edited interval or duration is guarded into a safe value.
Check.that("non-positive rotation interval reads as no auto-rotation",
           Playlist(name: "x", rotationInterval: 0).effectiveRotationInterval == nil)
Check.that("negative rotation interval reads as no auto-rotation",
           Playlist(name: "x", rotationInterval: -5).effectiveRotationInterval == nil)
Check.that("a positive rotation interval is honoured", Playlist(name: "x", rotationInterval: 60).effectiveRotationInterval == 60)
Check.that("a negative transition duration clamps to 0", TransitionSettings(kind: .crossfade, duration: -3).effectiveDuration == 0)
Check.that("a NaN transition duration clamps to 0", TransitionSettings(kind: .crossfade, duration: .nan).effectiveDuration == 0)

// MARK: RotationScheduler
Check.section("RotationScheduler")
do {
    let playlist = Playlist(name: "R", items: refs, mode: .inOrder, rotationInterval: 100)
    var sched = RotationScheduler(playlist: playlist, seed: 7, now: 0)
    Check.that("starts on the first item", sched.current == refs[0])
    Check.that("no advance before the interval elapses", sched.tick(now: 50) == nil)
    Check.that("still on the first item", sched.current == refs[0])
    Check.that("advances at t = interval", sched.tick(now: 100) == refs[1])
    Check.that("advances again at t = 2·interval", sched.tick(now: 200) == refs[2])
    Check.that("advances again at t = 3·interval", sched.tick(now: 300) == refs[3])
    Check.that("wraps back to the first item", sched.tick(now: 400) == refs[0])
    Check.that("a too-soon tick after an advance does nothing", sched.tick(now: 450) == nil)
}
do {
    // Manual next/previous jumps immediately and restarts the interval from now.
    var sched = RotationScheduler(playlist: Playlist(name: "R", items: refs, mode: .inOrder, rotationInterval: 100), seed: 7, now: 0)
    Check.that("manual next jumps to the second item", sched.next(now: 10) == refs[1])
    Check.that("the interval restarts from the manual jump (no auto-advance at t=60)", sched.tick(now: 60) == nil)
    Check.that("auto-advance resumes one interval after the jump", sched.tick(now: 110) == refs[2])
    Check.that("manual previous goes back", sched.previous(now: 120) == refs[1])
}
do {
    // Pause holds the elapsed time; resume continues from where it left off (no cut-short).
    var sched = RotationScheduler(playlist: Playlist(name: "R", items: refs, mode: .inOrder, rotationInterval: 100), seed: 7, now: 0)
    sched.pause(now: 40)                                    // 40 of 100 elapsed
    Check.that("paused does not advance even past the interval", sched.tick(now: 500) == nil)
    sched.resume(now: 500)                                  // 60 still to go
    Check.that("does not advance immediately on resume", sched.tick(now: 540) == nil)
    Check.that("advances once the remaining time elapses", sched.tick(now: 560) == refs[1])
}
do {
    // A manual skip WHILE paused resets the interval baseline: resume then gives the manually-selected
    // wallpaper a FULL interval, not the carried-over pre-skip remainder. (Before the fix, resume reused the
    // elapsed captured at pause and cut the manual pick short.)
    var sched = RotationScheduler(playlist: Playlist(name: "R", items: refs, mode: .inOrder, rotationInterval: 100), seed: 7, now: 0)
    sched.pause(now: 40)                                    // 40 of 100 elapsed, then frozen
    Check.that("manual next while paused changes the item", sched.next(now: 50) == refs[1])
    Check.that("a manual skip does not implicitly resume", sched.tick(now: 1000) == nil)
    sched.resume(now: 100)
    Check.that("the manual pick is not cut short by the pre-skip remainder", sched.tick(now: 160) == nil)
    Check.that("it advances a full interval after resume", sched.tick(now: 200) == refs[2])
}
do {
    // randomNoImmediateRepeat never shows the same wallpaper twice in a row.
    var sched = RotationScheduler(playlist: Playlist(name: "R", items: refs, mode: .randomNoImmediateRepeat, rotationInterval: 10), seed: 123, now: 0)
    var prev = sched.current
    var immediateRepeat = false
    for k in 1 ... 200 {
        if let next = sched.tick(now: Double(k) * 10) {
            if next == prev { immediateRepeat = true }
            prev = next
        }
    }
    Check.that("randomNoImmediateRepeat never repeats back-to-back", !immediateRepeat)
}
do {
    // Degenerate playlists never advance and never crash.
    var empty = RotationScheduler(playlist: Playlist(name: "E", items: [], mode: .inOrder, rotationInterval: 10), seed: 1, now: 0)
    Check.that("empty playlist has no current item", empty.current == nil)
    Check.that("empty playlist never advances", empty.tick(now: 1000) == nil)
    var single = RotationScheduler(playlist: Playlist(name: "1", items: [refs[0]], mode: .inOrder, rotationInterval: 10), seed: 1, now: 0)
    Check.that("single-item playlist stays put", single.tick(now: 1000) == nil && single.current == refs[0])
    var manual = RotationScheduler(playlist: Playlist(name: "M", items: refs, mode: .inOrder, rotationInterval: nil), seed: 1, now: 0)
    Check.that("a playlist with no interval never auto-advances", manual.tick(now: 1_000_000) == nil)
    Check.that("but manual next still works without an interval", manual.next(now: 0) == refs[1])
}

// MARK: PlaylistLibrary CRUD
Check.section("PlaylistLibrary")
do {
    func mk(_ n: String) -> Playlist { Playlist(name: n) }
    let a = mk("A"), b = mk("B"), c = mk("C")
    var lib = PlaylistLibrary([a, b, c])
    Check.that("library reports its count", lib.count == 3)
    Check.that("finds a playlist by id", lib.playlist(id: b.id)?.name == "B")
    // upsert: a new id appends, an existing id replaces in place.
    let d = mk("D")
    Check.that("upserting a new playlist inserts it", lib.upsert(d) == true && lib.count == 4)
    var bEdited = b; bEdited.name = "B2"
    Check.that("upserting an existing id replaces it (no insert)", lib.upsert(bEdited) == false && lib.count == 4)
    Check.that("the replacement kept its position", lib.playlists[1].name == "B2")
    // remove
    lib.remove(id: a.id)
    Check.that("remove drops the playlist", lib.count == 3 && lib.playlist(id: a.id) == nil)
    Check.that("remove of an absent id is a no-op", { var l = lib; l.remove(id: a.id); return l == lib }())
    // single move with clamping
    var ordered = PlaylistLibrary([a, b, c, d])
    ordered.move(from: 0, to: 2)
    Check.that("move shifts an item to a later index", ordered.playlists.map(\.name) == ["B", "C", "A", "D"])
    ordered.move(from: 3, to: 99)   // out-of-range target clamps to the end
    Check.that("move clamps an out-of-range target", ordered.playlists.last?.name == "D")
    // SwiftUI-style multi move
    var byOffsets = PlaylistLibrary([a, b, c, d])
    byOffsets.move(fromOffsets: IndexSet([0]), toOffset: 3)
    Check.that("move(fromOffsets:toOffset:) matches SwiftUI semantics", byOffsets.playlists.map(\.name) == ["B", "C", "A", "D"])
    // Codable round-trip of the whole library
    if let data = try? JSONEncoder().encode(ordered), let back = try? JSONDecoder().decode(PlaylistLibrary.self, from: data) {
        Check.that("the library round-trips through JSON", back == ordered)
    } else {
        Check.that("the library encodes/decodes", false)
    }
}

// MARK: TransitionController
Check.section("TransitionController")
do {
    var t = TransitionController()
    Check.that("idle incoming opacity is 1", t.incomingOpacity(at: 0) == 1)
    let fading = t.begin(.crossfade, duration: 2, now: 0)
    Check.that("begin crossfade keeps the old renderer alive", fading == true && t.phase == .crossfading)
    Check.that("incoming starts transparent", t.incomingOpacity(at: 0) == 0)
    Check.that("incoming is half-way at the midpoint", abs(t.incomingOpacity(at: 1) - 0.5) < 1e-9)
    Check.that("outgoing is the complement at the midpoint", abs(t.outgoingOpacity(at: 1) - 0.5) < 1e-9)
    Check.that("incoming is fully opaque at the end", t.incomingOpacity(at: 2) == 1)
    Check.that("opacity is clamped past the end", t.incomingOpacity(at: 5) == 1 && t.outgoingOpacity(at: 5) == 0)
    Check.that("tick before the end does not complete", t.tick(now: 1) == false && t.phase == .crossfading)
    Check.that("tick at the end completes once and goes idle", t.tick(now: 2) == true && t.phase == .idle)
    Check.that("a second tick after completion is false", t.tick(now: 3) == false)
}
do {
    var t = TransitionController()
    Check.that("a .none transition is a hard cut (drop the old renderer now)", t.begin(.none, duration: 2, now: 0) == false)
    Check.that("after a hard cut the incoming is fully visible immediately", t.incomingOpacity(at: 0) == 1)
    Check.that("a zero-duration crossfade is a hard cut", t.begin(.crossfade, duration: 0, now: 0) == false)
    Check.that("a negative-duration crossfade is a hard cut", t.begin(.crossfade, duration: -1, now: 0) == false)
    Check.that("a NaN-duration crossfade is a hard cut", t.begin(.crossfade, duration: .nan, now: 0) == false)
}

// MARK: DisplayAssignment (multi-monitor resolution)
Check.section("DisplayAssignment")
do {
    let main = WallpaperReference(id: "main"), side = WallpaperReference(id: "side")
    var assignment = DisplayAssignment(overrides: ["DISPLAY-1": side], fallback: main)
    Check.that("a display with an override uses it", assignment.reference(for: "DISPLAY-1") == side)
    Check.that("a display without an override uses the fallback", assignment.reference(for: "DISPLAY-2") == main)
    // resolve over the connected set
    let resolved = assignment.resolve(connectedDisplays: ["DISPLAY-1", "DISPLAY-2"])
    Check.that("resolve maps each connected display", resolved == ["DISPLAY-1": side, "DISPLAY-2": main])
    Check.that("an override for a disconnected display is ignored", assignment.resolve(connectedDisplays: ["DISPLAY-2"]) == ["DISPLAY-2": main])
    // no fallback → a display without an override shows nothing
    let noFallback = DisplayAssignment(overrides: ["DISPLAY-1": side])
    Check.that("with no fallback an unassigned display is omitted", noFallback.resolve(connectedDisplays: ["DISPLAY-1", "DISPLAY-2"]) == ["DISPLAY-1": side])
    // set/clear an override
    assignment.setOverride(main, for: "DISPLAY-2")
    Check.that("setOverride assigns a display", assignment.reference(for: "DISPLAY-2") == main && assignment.overrides.count == 2)
    assignment.setOverride(nil, for: "DISPLAY-1")
    Check.that("setOverride(nil) clears a display back to the fallback", assignment.overrides["DISPLAY-1"] == nil && assignment.reference(for: "DISPLAY-1") == main)
    // Codable
    if let data = try? JSONEncoder().encode(assignment), let back = try? JSONDecoder().decode(DisplayAssignment.self, from: data) {
        Check.that("the assignment round-trips through JSON", back == assignment)
    } else {
        Check.that("the assignment encodes/decodes", false)
    }
}
// Resolution diff: only the displays that changed need work.
do {
    let a = WallpaperReference(id: "a"), b = WallpaperReference(id: "b"), c = WallpaperReference(id: "c")
    let old = ["D1": a, "D2": b, "D3": c]
    let new = ["D1": a, "D2": c, "D4": b]   // D1 same, D2 changed, D3 removed, D4 added
    let diff = DisplayResolutionDiff(from: old, to: new)
    Check.that("diff finds the added display", diff.added == ["D4"])
    Check.that("diff finds the removed display", diff.removed == ["D3"])
    Check.that("diff finds the changed display", diff.changed == ["D2"])
    Check.that("diff finds the unchanged display", diff.unchanged == ["D1"])
    Check.that("an identical resolution diffs to empty", DisplayResolutionDiff(from: old, to: old).isEmpty)
}

// MARK: PlaybackPlan
Check.section("PlaybackPlan")
do {
    let all = Playlist(name: "All", items: [WallpaperReference(id: "x")], displayTarget: .all)
    let plan = PlaybackPlan(active: all, connectedDisplays: ["D1", "D2"])
    Check.that("an .all playlist plays on every display", plan.byDisplay.count == 2 && plan.playlist(forDisplay: "D1")?.id == all.id)
    let one = Playlist(name: "One", displayTarget: .display(uuid: "D1"))
    let targeted = PlaybackPlan(active: one, connectedDisplays: ["D1", "D2"])
    Check.that("a display-targeted playlist plays only on its display", targeted.byDisplay.keys.sorted() == ["D1"])
    Check.that("no active playlist yields an empty plan", PlaybackPlan(active: nil, connectedDisplays: ["D1"]).isEmpty)
    // diff: start / stop / restart
    let p1 = Playlist(name: "P1"), p2 = Playlist(name: "P2")
    let old = PlaybackPlan(byDisplay: ["D1": p1, "D2": p1])
    let new = PlaybackPlan(byDisplay: ["D1": p1, "D2": p2, "D3": p1])   // D1 same, D2 switched, D3 new, (none removed)
    let diff = PlaybackPlanDiff(from: old, to: new)
    Check.that("diff: a new display starts", diff.started == ["D3"])
    Check.that("diff: a switched playlist restarts", diff.restarted == ["D2"])
    Check.that("diff: an unchanged display is left alone", !diff.started.contains("D1") && !diff.restarted.contains("D1"))
    let removed = PlaybackPlanDiff(from: old, to: PlaybackPlan(byDisplay: ["D1": p1]))
    Check.that("diff: a dropped display stops", removed.stopped == ["D2"])
    // editing the active playlist (same id, changed contents) restarts it so the edit takes effect
    var edited = p1; edited.name = "P1-edited"
    Check.that("editing the active playlist's contents restarts it",
               PlaybackPlanDiff(from: PlaybackPlan(byDisplay: ["D1": p1]), to: PlaybackPlan(byDisplay: ["D1": edited])).restarted == ["D1"])
    Check.that("a byte-identical plan still leaves the display running (no gratuitous flash)",
               PlaybackPlanDiff(from: PlaybackPlan(byDisplay: ["D1": p1]), to: PlaybackPlan(byDisplay: ["D1": p1])).isEmpty)
}

// MARK: Preferences (Codable, tolerant of older saved values)
Check.section("Preferences")
do {
    // A round-trip preserves every field.
    let prefs = Preferences(showDockIcon: true, launchAtLogin: true, playlistPlayback: true)
    let data = try! JSONEncoder().encode(prefs)
    Check.that("preferences round-trip through Codable", (try? JSONDecoder().decode(Preferences.self, from: data)) == prefs)
    // A value saved by an OLDER build (no playlistPlayback key) still decodes, defaulting the missing field and
    // preserving the others — adding a preference must not reset everything.
    let old = Data(#"{"showDockIcon":true,"launchAtLogin":true}"#.utf8)
    if let decoded = try? JSONDecoder().decode(Preferences.self, from: old) {
        Check.that("an older preferences value decodes with the new field defaulted",
                   decoded.showDockIcon && decoded.launchAtLogin && decoded.playlistPlayback == false)
    } else {
        Check.that("older preferences value decodes (not rejected)", false)
    }
}

Check.summarize()

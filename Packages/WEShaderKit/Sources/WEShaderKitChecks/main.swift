// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room verification of the WE shader uniform/annotation extractor against a shader
// in the real WE dialect (CLT-only equivalent of unit tests).
import Foundation
import Metal
import WEShaderKit

// MARK: - Transpiler fuzzer (on demand: `WEShaderKitChecks fuzz [corpusDir] [iterations]`)

/// Deterministic PRNG so a crash/hang at iteration N reproduces exactly.
struct ShaderFuzzRNG {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(truncatingIfNeeded: next() >> 11) % n }
}

/// One of five mutations of a shader's source: truncate, random bytes, an overwritten run, an injected run of
/// nested parentheses (to stress the arithmetic-harmoniser recursion), or appended garbage.
func shaderMutate(_ seed: String, _ rng: inout ShaderFuzzRNG) -> String {
    var d = Array(seed.utf8)
    switch rng.below(5) {
    case 0: d = Array(d.prefix(rng.below(d.count + 1)))
    case 1: for _ in 0 ... rng.below(16) where !d.isEmpty { d[rng.below(d.count)] = UInt8(rng.below(256)) }
    case 2: if !d.isEmpty { let i = rng.below(d.count); let v = d[i]; for k in i ..< min(d.count, i + 1 + rng.below(64)) { d[k] = v } }
    case 3:   // moderate nesting (the 8192-char line guard bounds the recursion; 4000-deep is verified safe)
        let pad = Array(String(repeating: rng.below(2) == 0 ? "(" : ")", count: rng.below(500)).utf8)
        d.insert(contentsOf: pad, at: d.isEmpty ? 0 : rng.below(d.count))
    default: for _ in 0 ... rng.below(128) { d.append(UInt8(rng.below(256))) }
    }
    return String(decoding: d, as: UTF8.self)
}

/// Mutate corpus shaders and run each through the WE→MSL transpiler, looking for a trap or a hang (a
/// catastrophic regex, an unbounded recursion) that the transpiler — which runs on untrusted .pkg shaders at
/// render time — must never hit. A clean run is evidence it stays bounded on hostile input.
func runShaderFuzz(corpus: String, iters: Int) {
    var seeds: [String] = []
    if let names = try? FileManager.default.contentsOfDirectory(atPath: corpus) {
        for name in names where name.hasSuffix(".frag") || name.hasSuffix(".vert") {
            if let s = try? String(contentsOfFile: corpus + "/" + name, encoding: .utf8) { seeds.append(s) }
        }
    }
    guard !seeds.isEmpty else { print("shaderfuzz: no .frag/.vert in \(corpus)"); exit(1) }
    FileHandle.standardError.write(Data("shaderfuzz: \(seeds.count) seeds, \(iters) iters\n".utf8))
    for i in 0 ..< iters {
        var rng = ShaderFuzzRNG(state: UInt64(bitPattern: Int64(i)) &* 2654435761 &+ 0x9E37_79B9_7F4A_7C15)
        let m = shaderMutate(seeds[rng.below(seeds.count)], &rng)
        if i % 2 == 0 { _ = WEShaderTranspiler.fragmentToMSL(m) } else { _ = WEShaderTranspiler.vertexToMSL(m) }
        if i % 20_000 == 0 { FileHandle.standardError.write(Data("  shaderfuzz \(i)\n".utf8)) }
    }
    print("shaderfuzz: completed \(iters) iterations, 0 crashes/hangs")
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "fuzz" {
    let corpus = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/lumora_shaders"
    let iters = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 200_000) : 200_000
    runShaderFuzz(corpus: corpus, iters: iters)
    exit(0)
}

// Dev mode: a .frag file lists its uniforms (or, with a trailing `msl` argument, prints the transpiled
// Metal source with line numbers); a directory measures transpiler coverage (how many real shaders
// transpile to MSL that Metal accepts).
if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    if isDirectory.boolValue {
        let device = MTLCreateSystemDefaultDevice()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0.hasSuffix(".frag") || $0.hasSuffix(".vert") }.sorted()
        var compiled = 0, failed = 0, empty = 0
        var sampleErrors: [String] = []
        var emptyBodies: [String] = []
        for file in files {
            guard let source = try? String(contentsOfFile: path + "/" + file, encoding: .utf8),
                  let device else { continue }
            let isVertex = file.hasSuffix(".vert")
            let msl = isVertex ? WEShaderTranspiler.vertexToMSL(source)
                               : WEShaderTranspiler.fragmentToMSL(source)
            // A transpiled shader whose main body was lost compiles fine but does nothing — detect it by
            // checking the region between the output-local init and its return is whitespace-only.
            let (open, close) = isVertex ? ("VertexOut out;", "return out;") : ("float4 _fragColor = float4(0.0);", "return _fragColor;")
            if let o = msl.range(of: open), let c = msl.range(of: close, range: o.upperBound ..< msl.endIndex),
               msl[o.upperBound ..< c.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                empty += 1
                if emptyBodies.count < 8 { emptyBodies.append(file) }
            }
            do { _ = try device.makeLibrary(source: msl, options: nil); compiled += 1 }
            catch {
                failed += 1
                let first = "\(error)".components(separatedBy: "program_source:").last ?? "\(error)"
                if sampleErrors.count < 8 { sampleErrors.append("\(file): \(first.prefix(80).replacingOccurrences(of: "\n", with: " "))") }
            }
        }
        print("transpiler coverage: \(compiled)/\(compiled + failed) compile to MSL; \(empty) have an EMPTY body (lost)")
        for e in sampleErrors { print("  compile error: \(e)") }
        for e in emptyBodies { print("  empty body: \(e)") }
        exit(0)
    }
    if let real = try? String(contentsOfFile: path, encoding: .utf8), CommandLine.arguments.contains("msl") {
        let transpiled = path.hasSuffix(".vert") ? WEShaderTranspiler.vertexToMSL(real) : WEShaderTranspiler.fragmentToMSL(real)
        for (i, line) in transpiled.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            print(String(format: "%4d  %@", i + 1, String(line)))
        }
        exit(0)
    }
    if let real = try? String(contentsOfFile: path, encoding: .utf8) {
        let parsed = ShaderUniforms.parse(real)
        print("\(parsed.count) uniforms:")
        for uniform in parsed {
            print("  \(uniform.type) \(uniform.name)  material=\(uniform.material ?? "-")  default=\(uniform.defaultValue ?? "-")  range=\(uniform.range.map(String.init(describing:)) ?? "-")")
        }
    }
    exit(0)
}

// A fragment shader in WE's dialect (shape taken from real packaged effect shaders).
let source = """
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","default":"util/white"}
uniform float g_Threshold; // {"material":"ui_editor_properties_ray_threshold","default":0.5,"range":[0, 1]}
uniform vec3 g_Color; // {"material":"ui_editor_properties_color","default":"1 0.5 0.25"}
uniform mat4 g_ModelViewProjectionMatrix;

void main() {
    float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * mask * g_Threshold;
}
"""

let uniforms = ShaderUniforms.parse(source)

Check.section("ShaderUniforms")
Check.that("finds all five uniforms", uniforms.count == 5)
Check.that("first is sampler2D g_Texture0", uniforms[0].type == "sampler2D" && uniforms[0].name == "g_Texture0")
Check.that("captures the material label", uniforms[0].material == "ui_editor_properties_framebuffer")
Check.that("captures a string (asset path) default", uniforms[1].defaultValue == "util/white")
Check.that("captures a sampler's combo annotation", uniforms[1].combo == "MASK")
Check.that("a sampler with no combo annotation has nil combo", uniforms[0].combo == nil)
Check.that("captures a numeric default", uniforms[2].defaultValue == "0.5")
Check.that("captures a [min,max] range", uniforms[2].range == [0, 1])
Check.that("captures a vector default", uniforms[3].defaultValue == "1 0.5 0.25")
Check.that("includes an un-annotated built-in", uniforms[4].name == "g_ModelViewProjectionMatrix" && uniforms[4].material == nil)
Check.that("ignores varyings and other lines", !uniforms.contains { $0.name.hasPrefix("v_") })
Check.that("a shader with no uniforms parses to empty", ShaderUniforms.parse("void main() {}").isEmpty)
// Materials declare u_* user uniforms alongside g_* engine globals — capture both, or the body that
// references them fails to compile.
let userUniforms = ShaderUniforms.parse("uniform float u_alpha;\nuniform vec3 u_tint; // {\"default\":\"1 0 0\"}")
Check.that("captures u_* user uniforms, not only g_*",
           userUniforms.map(\.name) == ["u_alpha", "u_tint"] && userUniforms[1].defaultValue == "1 0 0")

// MARK: - WEShaderTranspiler

Check.section("WEShaderTranspiler")
let weShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer"}
uniform float g_Brightness; // {"material":"ui_editor_properties_brightness","default":1.0,"range":[0, 2]}
void main() {
    vec4 color = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = color * g_Brightness;
}
"""
let msl = WEShaderTranspiler.fragmentToMSL(weShader)
Check.that("rewrites texSample2D to a Metal sample call", msl.contains("g_Texture0.sample(g_Texture0_smp,"))
Check.that("qualifies a scalar uniform with the uniform buffer", msl.contains("u.g_Brightness"))
Check.that("qualifies a varying with stage_in", msl.contains("in.v_TexCoord"))
Check.that("maps vec4 to float4", msl.contains("float4 color"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        let library = try device.makeLibrary(source: msl, options: nil)
        Check.that("transpiled MSL compiles via Metal", library.makeFunction(name: "we_fragment") != nil)
    } catch {
        print("  ✗ transpiled MSL failed to compile: \(error)")
        print("──── MSL ────\n\(msl)\n─────────────")
        Check.that("transpiled MSL compiles via Metal", false)
    }
} else {
    print("  ⚠︎ no Metal device — skipping the MSL compile check")
}

// HLSL-style implicit vector truncation: WE shaders assign/pass a wider vector where a narrower one is
// wanted. MSL rejects that, so the transpiler inserts the leading-N swizzle for the cases it can type with
// confidence. A simple operand assigned to a narrower target, and a vec4 passed to a vec2-first-param func.
let truncShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    vec2 uv = v_TexCoord;
    vec2 spun = rotateVec2(v_TexCoord, 1.0);
    gl_FragColor = texSample2D(g_Texture0, uv + spun);
}
"""
let truncMSL = WEShaderTranspiler.fragmentToMSL(truncShader)
Check.that("truncates a vec4 assigned to a vec2 target", truncMSL.contains("float2 uv = in.v_TexCoord.xy"))
Check.that("truncates a vec4 arg to a vec2-param function", truncMSL.contains("rotateVec2(in.v_TexCoord.xy,"))
Check.that("leaves a correctly-dimensioned assignment alone", {
    let ok = WEShaderTranspiler.fragmentToMSL("varying vec4 v_TexCoord;\nvoid main() { vec2 uv = v_TexCoord.xy; gl_FragColor = vec4(uv, 0.0, 1.0); }")
    return ok.contains("float2 uv = in.v_TexCoord.xy") && !ok.contains(".xy.xy")
}())
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("truncated MSL compiles via Metal", (try? device.makeLibrary(source: truncMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}

// Component-wise intrinsics (mix/clamp/…) whose vector args disagree in width: WE passes the wider one
// (here vec4 over a vec3) and relies on implicit truncation. Harmonise to the narrowest vector width;
// scalars broadcast and stay. A call that already type-checks must be left exactly as-is.
let mixShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    vec3 tint = vec3(0.2, 0.4, 0.6);
    albedo.rgb = mix(albedo, tint, 0.5);
    gl_FragColor = albedo;
}
"""
let mixMSL = WEShaderTranspiler.fragmentToMSL(mixShader)
Check.that("harmonises a wider mix arg to the narrowest vector width", mixMSL.contains("mix(albedo.xyz, tint, 0.5)"))
Check.that("leaves a well-formed clamp(vec, scalar, scalar) untouched", {
    let ok = WEShaderTranspiler.fragmentToMSL("varying vec4 v_TexCoord;\nvoid main() { vec3 c = v_TexCoord.xyz; gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0); }")
    return ok.contains("clamp(c, 0.0, 1.0)")
}())
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("harmonised mix MSL compiles via Metal", (try? device.makeLibrary(source: mixMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// The WE dialect uses HLSL-spelled screen-space derivatives (ddx/ddy); Metal is dfdx/dfdy. A cloud/fluid
// shader sampling a gradient must have them renamed, or it fails to compile on an undeclared identifier.
let ddxShader = "varying vec4 v_TexCoord;\nvoid main() { vec2 g = vec2(ddx(v_TexCoord.x), ddy(v_TexCoord.y)); gl_FragColor = vec4(g, 0.0, 1.0); }"
let ddxMSL = WEShaderTranspiler.fragmentToMSL(ddxShader)
Check.that("renames ddx/ddy to dfdx/dfdy", ddxMSL.contains("dfdx(") && ddxMSL.contains("dfdy(") && !ddxMSL.contains("ddx(") && !ddxMSL.contains("ddy("))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("a ddx/ddy shader compiles via Metal after the rename", (try? device.makeLibrary(source: ddxMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}

// Plain arithmetic of mismatched-width operands (texture-transform shaders divide a vec2 offset by the
// vec4 g_*Resolution): truncate the wider operand to the narrowest vector width, like the dialect does.
// Both a same-width compound truncated to a narrower target and a vector·scalar chain stay correct.
let arithVert = """
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;
uniform vec2 g_TexOffset;
varying vec4 v_TexCoord;
void main() {
    gl_Position = vec4(a_Position, 1.0) * g_ModelViewProjectionMatrix;
    v_TexCoord = a_TexCoord.xyxy;
    vec2 scale = g_Texture0Resolution / g_Texture1Resolution;
    vec2 offset = g_TexOffset / g_Texture0Resolution;
    v_TexCoord.zw = v_TexCoord.zw * scale - offset;
}
"""
let arithMSL = WEShaderTranspiler.vertexToMSL(arithVert)
Check.that("harmonises a vec2 / vec4 to vec2 / vec4.xy", arithMSL.contains("g_TexOffset / u.g_Texture0Resolution.xy") || arithMSL.contains("u.g_TexOffset / u.g_Texture0Resolution.xy"))
Check.that("truncates a same-width compound assigned to a narrower target", arithMSL.contains(").xy"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("harmonised arithmetic MSL compiles via Metal", (try? device.makeLibrary(source: arithMSL, options: nil))?.makeFunction(name: "we_vertex") != nil)
}
// A `(…)`-grouped operand hides its own vec2/vec4 mismatch from the top-level chain (WE writes
// `(vec2 / g_*Resolution) * scalar`). Harmonising descends one paren level so the inner vec4 truncates,
// whether the mismatch is inside the group alone or the group then disagrees with a wider sibling.
let groupedTruncFrag = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Texture0Resolution;
uniform float g_Strength;
void main() {
    vec2 strength = (vec2(500.0) / g_Texture0Resolution) * g_Strength * g_Strength;
    vec4 wide = v_TexCoord;
    vec2 da = wide * (g_Texture0Resolution.xy * g_Strength) * 0.001;
    gl_FragColor = texSample2D(g_Texture0, strength + da);
}
"""
let groupedTruncMSL = WEShaderTranspiler.fragmentToMSL(groupedTruncFrag)
Check.that("truncates a vec4 inside a parenthesised operand (inner-only mismatch)",
           groupedTruncMSL.contains("(float2(500.0) / u.g_Texture0Resolution.xy)"))
Check.that("truncates a wider operand whose sibling is a parenthesised vec2 group",
           groupedTruncMSL.contains("float2 da = wide.xy *"))
Check.that("leaves a correctly-typed parenthesised arithmetic chain byte-identical", {
    // (vec2 + vec2) * vec2 already type-checks: no operand may grow a swizzle.
    let ok = WEShaderTranspiler.fragmentToMSL("""
    varying vec4 v_TexCoord;
    void main() { vec2 a = v_TexCoord.xy; vec2 r = (a + a) * a; gl_FragColor = vec4(r, 0.0, 1.0); }
    """)
    return ok.contains("float2 r = (a + a) * a;") && !ok.contains(").xy")
}())
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("a grouped-truncation shader compiles via Metal",
               (try? device.makeLibrary(source: groupedTruncMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// Width-mismatched arithmetic *inside a function-call argument* — not just at an assignment's top level.
// WE's chromatic-aberration writes `texSample2D(g_Texture0, v_TexCoord.xy - (u_bOffset * timer + pointer))`
// (vec2 − vec4 group) and its cutout-vignette writes `abs(v_TexCoord - u_offset)` (vec3 − vec2); the larger
// operand must truncate to the narrower, which MSL rejects. The harmoniser descends into every call's args.
let callArgFrag = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float u_bOffset;
void main() {
    vec4 timer = texSample2D(g_Texture0, v_TexCoord.xy);
    float pointer = 0.5;
    vec4 bValue = texSample2D(g_Texture0, v_TexCoord.xy - (u_bOffset * timer + pointer));
    gl_FragColor = bValue;
}
"""
let callArgMSL = WEShaderTranspiler.fragmentToMSL(callArgFrag)
Check.that("truncates a vec4 group subtracted from a vec2 inside a sample() argument",
           callArgMSL.contains("(u.u_bOffset * timer + pointer).xy"))
let cutoutFrag = """
varying vec3 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec2 u_offset;
uniform float u_scale;
void main() {
    vec3 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    float scale = pow(length(abs(v_TexCoord - u_offset)), 3.0) * u_scale;
    gl_FragColor = vec4(albedo.rgb * scale, 1.0);
}
"""
let cutoutMSL = WEShaderTranspiler.fragmentToMSL(cutoutFrag)
Check.that("truncates a vec3 to vec2 inside an abs() argument (cutout-vignette shape)",
           cutoutMSL.contains("abs(in.v_TexCoord.xy - u.u_offset)"))
Check.that("leaves a correctly-typed call argument byte-identical", {
    // `v_TexCoord.xy - u_shift` is vec2 − vec2: no operand may grow a swizzle.
    let ok = WEShaderTranspiler.fragmentToMSL("""
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform vec2 u_shift;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy - u_shift); }
    """)
    return ok.contains("in.v_TexCoord.xy - u.u_shift)") && !ok.contains(".xy.xy") && !ok.contains("u_shift.xy")
}())
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("call-argument-truncation shaders compile via Metal",
               (try? device.makeLibrary(source: callArgMSL, options: nil))?.makeFunction(name: "we_fragment") != nil &&
               (try? device.makeLibrary(source: cutoutMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// GLSL `discard;` (alpha-test / cutout fragments) lowers to MSL `discard_fragment();`.
let discardFrag = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    vec4 c = texSample2D(g_Texture0, v_TexCoord.xy);
    if (c.a < 0.5) discard;
    gl_FragColor = c;
}
"""
let discardMSL = WEShaderTranspiler.fragmentToMSL(discardFrag)
Check.that("rewrites GLSL discard to MSL discard_fragment()", discardMSL.contains("discard_fragment()"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("discard MSL compiles via Metal", (try? device.makeLibrary(source: discardMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// GLSL bvec/uvec types and the component-wise relational builtins (lessThan/…) lower to Metal's bool/uint
// vectors and its vector relational operators (which return the same component-wise bool vector).
let relFrag = """
varying vec4 v_TexCoord;
void main() {
    vec3 a = v_TexCoord.xyz;
    vec3 b = vec3(0.5);
    bvec3 lo = lessThan(a, b);
    gl_FragColor = any(lo) ? vec4(1.0) : vec4(0.0);
}
"""
let relMSL = WEShaderTranspiler.fragmentToMSL(relFrag)
Check.that("lowers bvec3 + the lessThan relational builtin", relMSL.contains("bool3") && !relMSL.contains("lessThan("))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("relational/bvec MSL compiles via Metal", (try? device.makeLibrary(source: relMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// An ivec uniform's struct member must lower to Metal's int vector — the body rewrite already maps
// ivec→int, but a uniform/varying/attribute member is typed by mslType(), which must agree or Metal rejects
// the whole Uniforms struct ("cannot be used in buffer pointee type").
let ivecFrag = """
varying vec4 v_TexCoord;
uniform ivec2 g_Cells; // {"material":"cells"}
void main() {
    int n = g_Cells.x + g_Cells.y;
    gl_FragColor = vec4(float(n));
}
"""
let ivecMSL = WEShaderTranspiler.fragmentToMSL(ivecFrag)
Check.that("an ivec uniform member lowers to int2, not raw ivec2", ivecMSL.contains("int2 g_Cells") && !ivecMSL.contains("ivec2"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("ivec-uniform MSL compiles via Metal", (try? device.makeLibrary(source: ivecMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// The rest of mslType()'s matrix/vector cases are reached the same way — by typing a uniform struct member —
// and Metal rejects the whole Uniforms struct if any one lowers to its raw GLSL spelling. Lock each so a
// dropped switch case can't slip through (mat4 is covered implicitly by g_ModelViewProjectionMatrix everywhere).
let mat2Frag = """
varying vec4 v_TexCoord;
uniform mat2 g_Transform; // {"material":"xf"}
void main() { vec2 v = g_Transform * vec2(1.0, 0.0); gl_FragColor = vec4(v, 0.0, 1.0); }
"""
let mat2MSL = WEShaderTranspiler.fragmentToMSL(mat2Frag)
Check.that("a mat2 uniform member lowers to float2x2, not raw mat2", mat2MSL.contains("float2x2 g_Transform") && !mat2MSL.contains("mat2"))
let uvecFrag = """
varying vec4 v_TexCoord;
uniform uvec2 g_Grid; // {"material":"g"}
uniform uvec3 g_Cells; // {"material":"c"}
uniform uvec4 g_Mask; // {"material":"m"}
void main() { gl_FragColor = vec4(float(g_Grid.x + g_Cells.y + g_Mask.w)); }
"""
let uvecMSL = WEShaderTranspiler.fragmentToMSL(uvecFrag)
Check.that("uvec uniform members lower to uint2/uint3/uint4, not raw uvec",
           uvecMSL.contains("uint2 g_Grid") && uvecMSL.contains("uint3 g_Cells") && uvecMSL.contains("uint4 g_Mask") && !uvecMSL.contains("uvec"))
let bvec4Frag = """
varying vec4 v_TexCoord;
uniform bvec4 g_Flags; // {"material":"f"}
void main() { gl_FragColor = any(g_Flags) ? vec4(1.0) : vec4(0.0); }
"""
let bvec4MSL = WEShaderTranspiler.fragmentToMSL(bvec4Frag)
Check.that("a bvec4 uniform member lowers to bool4, not raw bvec4", bvec4MSL.contains("bool4 g_Flags") && !bvec4MSL.contains("bvec4"))
// A comparison sampler binds as a depth texture (depth2d), not a colour texture2d — shadow-map shaders rely on it.
let cmpFrag = """
varying vec4 v_TexCoord;
uniform sampler2DComparison g_ShadowMap; // {"material":"shadow"}
void main() { gl_FragColor = vec4(0.0); }
"""
let cmpMSL = WEShaderTranspiler.fragmentToMSL(cmpFrag)
Check.that("a sampler2DComparison binds as depth2d<float>, not texture2d", cmpMSL.contains("depth2d<float> g_ShadowMap"))
if let device = MTLCreateSystemDefaultDevice() {
    for (label, src) in [("mat2", mat2MSL), ("uvec", uvecMSL), ("bvec4", bvec4MSL)] {
        Check.that("\(label)-uniform MSL compiles via Metal", (try? device.makeLibrary(source: src, options: nil))?.makeFunction(name: "we_fragment") != nil)
    }
}

// gl_FragCoord (window-space pixel coordinate) wires to MSL's [[position]] fragment parameter.
let fcFrag = """
varying vec4 v_TexCoord;
uniform vec4 g_Texture0Resolution;
void main() {
    vec2 uv = gl_FragCoord.xy / g_Texture0Resolution.xy;
    gl_FragColor = vec4(uv, 0.0, 1.0);
}
"""
let fcMSL = WEShaderTranspiler.fragmentToMSL(fcFrag)
Check.that("wires gl_FragCoord to a [[position]] parameter", fcMSL.contains("[[position]]") && fcMSL.contains("_fragCoord") && !fcMSL.contains("gl_FragCoord"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("gl_FragCoord MSL compiles via Metal", (try? device.makeLibrary(source: fcMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
// A function definition in an included header must not register its name as a variable dimension (a
// `vec3 blend(...)` helper would otherwise mis-type a later `float blend` local and force a bad swizzle).
Check.that("a vecN function name is not mistaken for a vecN variable", {
    let m = WEShaderTranspiler.fragmentToMSL("""
    uniform sampler2D g_Texture0;
    uniform float g_Multiply;
    varying vec4 v_TexCoord;
    vec3 blend(vec3 a, vec3 b) { return a * b; }
    void main() { float k = 1.0; float scaled = k * g_Multiply; gl_FragColor = float4(scaled); }
    """)
    return m.contains("float scaled = k * u.g_Multiply") && !m.contains("(k * u.g_Multiply)")
}())

// A texture sample is a float4; WE assigns it straight to a scalar opacity mask and relies on implicit
// truncation (`float mask = texSample2D(...)`). Truncate to the target's width.
let maskShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
void main() {
    float4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    float mask = texSample2D(g_Texture1, v_TexCoord.xy);
    gl_FragColor = albedo * mask;
}
"""
let maskMSL = WEShaderTranspiler.fragmentToMSL(maskShader)
Check.that("truncates a texture sample assigned to a scalar mask", maskMSL.contains("float mask = g_Texture1.sample(g_Texture1_smp, in.v_TexCoord.xy).x"))
Check.that("leaves a sample assigned to a float4 alone", maskMSL.contains("float4 albedo = g_Texture0.sample(g_Texture0_smp, in.v_TexCoord.xy);"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("scalar-mask sample MSL compiles via Metal", (try? device.makeLibrary(source: maskMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}

// Regression (fuzzer-found): a malformed shader whose ')' precedes its '(' made globalHelperLambdas slice an
// inverted Range (lowerBound > upperBound) and trap. A corrupt .pkg shader must degrade, not crash the loader —
// reaching these assertions proves the transpile no longer traps, and it still emits the MSL scaffold.
Check.that("an inverted-paren signature transpiles to a vertex scaffold without trapping",
           WEShaderTranspiler.vertexToMSL("{}e)({g_}").contains("return out;"))
Check.that("the same malformed signature is safe in the fragment path too",
           WEShaderTranspiler.fragmentToMSL("{}e)({g_}").contains("return _fragColor;"))

// coerceVectorTruncations' harmonisers run O(N^2) on one giant line, so a line over 8 KB is passed through
// UNHARMONISED (the DoS guard). Verify that DETERMINISTICALLY, not by wall clock: a truncatable mix below the
// threshold gets its vec4 arg narrowed to .xy, but the same construct padded past 8 KB is left untouched.
let dosTruncMSL = WEShaderTranspiler.fragmentToMSL(
    "varying vec4 v_TexCoord;\nvoid main(){ vec2 vv = vec2(0.0); vec2 r = mix(v_TexCoord, vv, 0.5); gl_FragColor = vec4(r, 0.0, 1.0); }")
Check.that("a short truncatable mix is harmonised (vec4 arg -> .xy)", dosTruncMSL.contains("mix(in.v_TexCoord.xy, vv"))
let dosPad = String(repeating: " ", count: 9000)   // pushes the line past the 8 KB guard without adding tokens
let dosLongMSL = WEShaderTranspiler.fragmentToMSL(
    "varying vec4 v_TexCoord;\nvoid main(){ vec2 vv = vec2(0.0); vec2 r = mix(v_TexCoord, vv, 0.5)\(dosPad); gl_FragColor = vec4(r, 0.0, 1.0); }")
Check.that("an over-8KB line skips the harmonisers (DoS guard fires, no .xy added)",
           dosLongMSL.contains("mix(in.v_TexCoord, vv") && !dosLongMSL.contains("in.v_TexCoord.xy"))

// GLSL's length(scalar) is its magnitude; MSL has no scalar overload (ambiguous), so rewrite to abs().
// A length() of a genuine vector must be left alone.
let lenShader = """
varying vec4 v_TexCoord;
uniform vec2 g_Center;
void main() {
    float dx = length(v_TexCoord.x - g_Center.x);
    float dv = length(v_TexCoord.xy - g_Center);
    gl_FragColor = vec4(dx + dv);
}
"""
let lenMSL = WEShaderTranspiler.fragmentToMSL(lenShader)
Check.that("rewrites length() of a scalar to abs()", lenMSL.contains("abs(in.v_TexCoord.x - u.g_Center.x)"))
Check.that("leaves length() of a vector as length()", lenMSL.contains("length(in.v_TexCoord.xy - u.g_Center)"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("scalar-length MSL compiles via Metal", (try? device.makeLibrary(source: lenMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}

// GLSL lets a local shadow a varying of the same name (chromatic aberration recomputes `bValue` over the
// interpolated one). The local owns the name inside main, so it must NOT be qualified to in.bValue —
// qualifying the declaration would emit the invalid `float4 in.bValue = …`.
let varyShadowShader = """
varying vec4 v_TexCoord;
varying vec4 bValue;
uniform sampler2D g_Texture0;
void main() {
    vec4 bValue = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = bValue;
}
"""
let varyShadowMSL = WEShaderTranspiler.fragmentToMSL(varyShadowShader)
Check.that("a local shadowing a varying is not qualified", varyShadowMSL.contains("float4 bValue =") && !varyShadowMSL.contains("in.bValue ="))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("a varying-shadowing local compiles", (try? device.makeLibrary(source: varyShadowMSL, options: nil)) != nil)
}
// The same shadowing rule must hold for a local that shadows a UNIFORM name — otherwise the local's own
// declaration `float2 g_Color = …;` is rewritten to the invalid declarator `float2 u.g_Color = …;`.
let uniformShadowShader = """
varying vec4 v_TexCoord;
uniform vec4 g_Color; // {"material":"color"}
void main() {
    vec2 g_Color = v_TexCoord.xy;
    gl_FragColor = vec4(g_Color, 0.0, 1.0);
}
"""
let uniformShadowMSL = WEShaderTranspiler.fragmentToMSL(uniformShadowShader)
Check.that("a local shadowing a uniform is not qualified", uniformShadowMSL.contains("float2 g_Color =") && !uniformShadowMSL.contains("u.g_Color ="))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("a uniform-shadowing local compiles", (try? device.makeLibrary(source: uniformShadowMSL, options: nil)) != nil)
}

// Uniforms aren't always g_/u_ prefixed (tone mapping's are t_*). A helper referencing one must be hosted
// as a capturing lambda inside main (so it sees the uniform buffer), not emitted as a free function.
let prefixShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float t_white; // {"material":"white","default":2.0}
float tonemap(float l) { return 1.0 - exp(-l / t_white); }
void main() {
    vec4 c = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = vec4(tonemap(c.r), tonemap(c.g), tonemap(c.b), 1.0);
}
"""
let prefixMSL = WEShaderTranspiler.fragmentToMSL(prefixShader)
Check.that("a helper using a t_* uniform reads it via the buffer", prefixMSL.contains("u.t_white"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("a non-g_/u_ uniform helper compiles", (try? device.makeLibrary(source: prefixMSL, options: nil)) != nil)
}

// The prelude provides the standard HSV<->RGB helpers for gradient/hue shaders that don't ship their own.
Check.that("prelude defines hsv2rgb and rgb2hsv", WEShaderPrelude.msl.contains("hsv2rgb") && WEShaderPrelude.msl.contains("rgb2hsv"))

// A pure helper defined AFTER main() must be emitted at file scope, not swallowed into main's body.
// Under the old "body runs to the file's last }" rule the helper landed inside main and was also
// emitted separately, so the shader failed to compile (a nested/duplicate definition).
let helperAfterMain = """
varying vec4 v_TexCoord;
uniform float g_Amount; // {"material":"ui_editor_properties_amount","default":1.0}
void main() {
    float v = boost(g_Amount);
    gl_FragColor = vec4(v, v, v, 1.0);
}
float boost(float x) {
    return x * 2.0 + 1.0;
}
"""
let helperMSL = WEShaderTranspiler.fragmentToMSL(helperAfterMain)
Check.that("emits a trailing helper at file scope", helperMSL.contains("boost"))
Check.that("main still calls the helper", helperMSL.contains("boost(u.g_Amount)"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: helperMSL, options: nil)
        Check.that("a helper defined after main compiles", true)
    } catch {
        print("──── MSL ────\n\(helperMSL)\n─────────────")
        Check.that("a helper defined after main compiles", false)
    }
}

// A block comment between two tokens is whitespace, not nothing — it must not fuse them into one.
let withInlineComment = WEShaderTranspiler.fragmentToMSL("""
varying vec4 v_TexCoord;
void main() {
    float/* inline */value = 0.5;
    gl_FragColor = vec4(value, value, value, 1.0);
}
""")
Check.that("a block comment doesn't fuse the tokens around it",
           !withInlineComment.contains("floatvalue") && withInlineComment.contains("value"))

// WE shaders assume math constants and helpers from their unshipped common headers; the prelude supplies
// them. WE's M_PI_2 is tau (a full turn), and M_PI_HALF is the genuine π/2 — a shader using both must
// transpile to MSL that Metal accepts.
let preludeShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, rotateVec2(v_TexCoord.xy, M_PI_2 * 0.25 + M_PI_HALF)); }
"""
if let device = MTLCreateSystemDefaultDevice() {
    let preludeMSL = WEShaderTranspiler.fragmentToMSL(preludeShader)
    Check.that("prelude compiles a shader using M_PI_2 (tau), M_PI_HALF and rotateVec2",
               (try? device.makeLibrary(source: preludeMSL, options: nil)) != nil)

    // A combo declared in a // [COMBO] header seeds its default; ApplyBlending(BLENDMODE, …) then
    // resolves to that integer and the blending prelude supplies the function.
    let blendShader = """
    // [COMBO] {"combo":"BLENDMODE","type":"imageblending","default":2}
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform vec3 g_Tint; // {"default":"1 0 0"}
    void main() {
        vec4 a = texSample2D(g_Texture0, v_TexCoord.xy);
        gl_FragColor = vec4(ApplyBlending(BLENDMODE, a.rgb, a.rgb * g_Tint, 0.5), a.a);
    }
    """
    let blendMSL = WEShaderTranspiler.fragmentToMSL(blendShader)
    Check.that("seeds combo defaults and injects BLENDMODE as a #define", blendMSL.contains("#define BLENDMODE 2"))
    Check.that("blending prelude compiles an ApplyBlending shader",
               (try? device.makeLibrary(source: blendMSL, options: nil)) != nil)

    // GLSL mod (floor-based) and two-argument atan (atan2) must compile via the prelude, not Metal's
    // fmod/one-arg atan.
    let mathShader = """
    varying vec4 v_TexCoord;
    void main() { gl_FragColor = vec4(mod(v_TexCoord.x, 2.0), atan(v_TexCoord.y, v_TexCoord.x), 0.0, 1.0); }
    """
    Check.that("prelude compiles GLSL mod and two-arg atan",
               (try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(mathShader), options: nil)) != nil)

    // The two-argument atan(y, x) overload must also cover float4: without it, atan(vec4, vec4) finds no
    // overload, the shader fails to compile, and the effect is silently dropped to a no-op.
    let atan4Shader = """
    varying vec4 v_TexCoord;
    void main() { gl_FragColor = atan(v_TexCoord, v_TexCoord.wzyx); }
    """
    Check.that("prelude compiles a two-arg atan on float4",
               (try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(atan4Shader), options: nil)) != nil)

    // The combine pass of a multi-pass blur folds the blurred buffer over the original via
    // common_composite.h (ApplyComposite / ApplyCompositeOffset). It must transpile and compile so the
    // four-pass blur graph completes instead of being dropped.
    let combineShader = """
    // [COMBO] {"combo":"COMPOSITE","type":"options","default":0}
    #include "common_composite.h"
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0; // {"hidden":true}
    uniform sampler2D g_Texture2; // {"hidden":true}
    uniform vec4 g_Texture0Resolution;
    void main() {
        vec4 blurred = texSample2D(g_Texture0, ApplyCompositeOffset(v_TexCoord.xy, g_Texture0Resolution.xy));
        vec4 albedoOld = texSample2D(g_Texture2, v_TexCoord.xy);
        gl_FragColor = ApplyComposite(albedoOld, blurred);
    }
    """
    Check.that("common_composite.h compiles a blur-combine shader",
               (try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(combineShader), options: nil)) != nil)
}
// A fragment varying the shader never reads is dropped from stage_in — left in, it shifts every later
// varying's location and the pass fails to link against the vertex (waterripple's unused v_Scroll).
let unusedVaryingFrag = """
varying vec4 v_TexCoord;
varying vec2 v_Unused;
varying vec4 v_Used;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) + v_Used; }
"""
let unusedVaryingMSL = WEShaderTranspiler.fragmentToMSL(unusedVaryingFrag)
Check.that("an unread fragment varying is dropped from stage_in", !unusedVaryingMSL.contains("v_Unused"))
Check.that("a read fragment varying is kept in stage_in", unusedVaryingMSL.contains("v_Used"))

Check.that("comboDefaults reads the // [COMBO] default",
           ShaderPreprocessor.comboDefaults("// [COMBO] {\"combo\":\"BLENDMODE\",\"default\":9}\nvoid main(){}")["BLENDMODE"] == 9)
Check.that("an explicit combo overrides the annotation default",
           WEShaderTranspiler.fragmentToMSL("// [COMBO] {\"combo\":\"BLENDMODE\",\"default\":9}\nvoid main(){}", combos: ["BLENDMODE": 3]).contains("#define BLENDMODE 3"))

let weVertex = """
attribute vec3 a_Position;
attribute vec4 a_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
varying vec4 v_TexCoord;
void main() {
    gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
    v_TexCoord = a_TexCoord;
}
"""
let vertexMSL = WEShaderTranspiler.vertexToMSL(weVertex)
Check.that("vertex: attribute becomes stage_in", vertexMSL.contains("in.a_Position"))
Check.that("vertex: gl_Position becomes the output position", vertexMSL.contains("out.position ="))
Check.that("vertex: varying becomes an output", vertexMSL.contains("out.v_TexCoord"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        let library = try device.makeLibrary(source: vertexMSL, options: nil)
        Check.that("transpiled vertex MSL compiles via Metal", library.makeFunction(name: "we_vertex") != nil)
    } catch {
        print("  ✗ transpiled vertex MSL failed to compile: \(error)")
        print("──── MSL ────\n\(vertexMSL)\n─────────────")
        Check.that("transpiled vertex MSL compiles via Metal", false)
    }
}

// Array varyings — the blur/godray/downsample family declares `varying vec2 v_TexCoord[N]` and indexes
// it with a loop variable. MSL forbids an array member in a stage_in / vertex-out struct, so the
// transpiler expands it into per-element members and rebuilds a local array the body can index.
let arrayVertex = """
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord[4];
varying vec2 v_TexCoordBase;
void main() {
    gl_Position = vec4(a_Position, 1.0);
    v_TexCoordBase = a_TexCoord;
    for (int i = 0; i < 4; i++) v_TexCoord[i] = a_TexCoord;
}
"""
let arrayVertexMSL = WEShaderTranspiler.vertexToMSL(arrayVertex)
Check.that("array varying expands into per-element output members", arrayVertexMSL.contains("v_TexCoord_0 [[user(locn"))
Check.that("a later scalar varying takes the location after the array's elements", arrayVertexMSL.contains("v_TexCoordBase [[user(locn4)]]"))
Check.that("the array varying is written via a local copied to the output", arrayVertexMSL.contains("out.v_TexCoord_0 = v_TexCoord[0]"))
let arrayFragment = """
varying vec2 v_TexCoord[4];
uniform sampler2D g_Texture0;
void main() {
    vec4 sum = vec4(0.0);
    for (int i = 0; i < 4; i++) sum += texSample2D(g_Texture0, v_TexCoord[i]);
    gl_FragColor = sum;
}
"""
let arrayFragmentMSL = WEShaderTranspiler.fragmentToMSL(arrayFragment)
Check.that("array varying rebuilds a local array from stage_in", arrayFragmentMSL.contains("float2 v_TexCoord[4] = {"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: arrayVertexMSL, options: nil)
        _ = try device.makeLibrary(source: arrayFragmentMSL, options: nil)
        Check.that("an array-varying vertex and fragment both compile", true)
    } catch {
        print("──── vertex ────\n\(arrayVertexMSL)\n──── fragment ────\n\(arrayFragmentMSL)\n─────────────")
        Check.that("an array-varying vertex and fragment both compile", false)
    }
}
// A wallpaper's shader bytes are untrusted, so an absurd array-varying length must not expand to millions
// of stage-in members (OOM); it is treated as non-array and the shader degrades to a no-op.
let hugeArrayMSL = WEShaderTranspiler.fragmentToMSL("""
varying vec2 v_TexCoord[999999999];
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord[0]); }
""")
Check.that("an over-long array varying is not expanded to millions of members", hugeArrayMSL.count < 100_000)

// The bundled clean-room headers declare the blend/colour helpers WE shaders pull in with #include.
// A shader calling BlendOpacity (common_blending.h) and hsv2rgb/rgb2hsv (common.h) must transpile to
// MSL that Metal accepts.
let headerShader = """
#include "common.h"
#include "common_blending.h"
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    vec3 tinted = hsv2rgb(rgb2hsv(albedo.rgb));
    gl_FragColor = vec4(BlendOpacity(albedo.rgb, tinted, BlendLinearDodge, 0.5), albedo.a);
}
"""
let headerMSL = WEShaderTranspiler.fragmentToMSL(headerShader)
Check.that("splices the bundled header helpers into the shader", headerMSL.contains("hsv2rgb") && headerMSL.contains("BlendOpacity"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: headerMSL, options: nil)
        Check.that("an #include-using shader compiles via the bundled headers", true)
    } catch {
        print("──── MSL ────\n\(headerMSL)\n─────────────")
        Check.that("an #include-using shader compiles via the bundled headers", false)
    }
}

// common_blur.h: the blur macro injects the framebuffer (g_Texture0) into a free function, so a separable
// gaussian-blur shader (which calls blur13a(centre, step)) transpiles and compiles.
let blurShader = """
#include "common_blur.h"
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = blur13a(v_TexCoord.xy, v_TexCoord.zw);
}
"""
let blurMSL = WEShaderTranspiler.fragmentToMSL(blurShader)
Check.that("the blur macro injects the framebuffer into a free function", blurMSL.contains("_weBlur13(g_Texture0"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: blurMSL, options: nil)
        Check.that("a gaussian-blur shader compiles via common_blur.h", true)
    } catch {
        print("──── MSL ────\n\(blurMSL)\n─────────────")
        Check.that("a gaussian-blur shader compiles via common_blur.h", false)
    }
}

// Perspective/parallax vertex effects: GLSL's inverse() and mat3(mat4) have no Metal equivalent, so the
// prelude supplies inverse(float3x3) and CAST3X3 lowers to _weCast3x3; squareToQuad comes from the header.
let matrixVert = """
#include "common_perspective.h"
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_EffectMatrix;
uniform vec2 g_Point0;
uniform vec2 g_Point1;
uniform vec2 g_Point2;
uniform vec2 g_Point3;
varying vec3 v_Warp;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
    mat3 rot = CAST3X3(g_EffectMatrix);
    v_Warp = mul(vec3(a_TexCoord, 1.0), xform) + rot[0];
}
"""
let matrixMSL = WEShaderTranspiler.vertexToMSL(matrixVert)
Check.that("CAST3X3 lowers to the matrix-truncation helper, not float3x3(mat4)", matrixMSL.contains("_weCast3x3("))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: matrixMSL, options: nil)
        Check.that("a perspective vertex shader compiles (inverse, squareToQuad, CAST3X3)", true)
    } catch {
        print("──── MSL ────\n\(matrixMSL)\n─────────────")
        Check.that("a perspective vertex shader compiles (inverse, squareToQuad, CAST3X3)", false)
    }
}

// File-scope const declarations (e.g. WE's ACES tone-map matrices) must be emitted in the constant
// address space so helpers and main that read them resolve — they're neither functions nor structs.
let constShader = """
const mat3 m = mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
vec3 apply(vec3 c) { return mul(m, c); }
void main() {
    vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = vec4(apply(albedo.rgb), albedo.a);
}
"""
let constMSL = WEShaderTranspiler.fragmentToMSL(constShader)
Check.that("emits a file-scope const in the constant address space", constMSL.contains("constant float3x3 m"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: constMSL, options: nil)
        Check.that("a shader with a file-scope const matrix compiles", true)
    } catch {
        print("──── MSL ────\n\(constMSL)\n─────────────")
        Check.that("a shader with a file-scope const matrix compiles", false)
    }
}

// A shader's own definition of a prelude helper (e.g. its BlendTransparency transparency-mode switch) is
// authoritative: it must be emitted and the prelude's generic version dropped, or the shader's blend is
// silently replaced by the wrong one — and emitting both would be a redefinition error.
let shadowShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
float BlendTransparency(float base, float blend, float opacity) {
    return base * blend * opacity * 0.5;
}
void main() {
    vec4 a = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = vec4(a.rgb, BlendTransparency(a.a, 1.0, 0.5));
}
"""
let shadowMSL = WEShaderTranspiler.fragmentToMSL(shadowShader)
Check.that("a shader's own helper shadows the prelude's version", shadowMSL.contains("base * blend * opacity * 0.5"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: shadowMSL, options: nil)
        Check.that("the shadowing shader compiles (prelude copy dropped, no redefinition)", true)
    } catch {
        print("──── MSL ────\n\(shadowMSL)\n─────────────")
        Check.that("the shadowing shader compiles (prelude copy dropped, no redefinition)", false)
    }
}

// A shader redefining a MULTI-overload prelude function (mod has several) must have ALL the prelude's
// overloads dropped — here it redefines the vec2 overload, which isn't the first, so removing only the
// first would leave the prelude's vec2 mod to collide.
let overloadShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
vec2 mod(vec2 x, vec2 y) { return x - y * floor(x / y) + 0.001; }
void main() { gl_FragColor = vec4(mod(v_TexCoord.xy, vec2(2.0)), 0.0, 1.0); }
"""
let overloadMSL = WEShaderTranspiler.fragmentToMSL(overloadShader)
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: overloadMSL, options: nil)
        Check.that("redefining a non-first overload of a prelude function compiles", true)
    } catch {
        print("──── MSL ────\n\(overloadMSL)\n─────────────")
        Check.that("redefining a non-first overload of a prelude function compiles", false)
    }
}

// An in-file helper that samples a texture or reads a uniform can't be a free MSL function (it can't see
// the fragment's globals); it's hosted as a lambda inside main. A helper that only CALLS such a helper is
// hosted too (transitively), so it can reach the lambda.
let lambdaShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Amount;
vec3 sampleAt(vec2 uv) { return texSample2D(g_Texture0, uv).rgb * g_Amount; }
vec3 doubleSample(vec2 uv) { return sampleAt(uv) + sampleAt(uv + vec2(0.1)); }
void main() {
    gl_FragColor = vec4(doubleSample(v_TexCoord.xy), 1.0);
}
"""
let lambdaMSL = WEShaderTranspiler.fragmentToMSL(lambdaShader)
Check.that("a global-touching helper is hosted as a lambda in main", lambdaMSL.contains("auto sampleAt = [&]"))
Check.that("a helper that only calls a global-touching one is hosted too (transitive)", lambdaMSL.contains("auto doubleSample = [&]"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: lambdaMSL, options: nil)
        Check.that("a shader with global-touching in-file helpers compiles", true)
    } catch {
        print("──── MSL ────\n\(lambdaMSL)\n─────────────")
        Check.that("a shader with global-touching in-file helpers compiles", false)
    }
}

// A GLSL array constructor T[N](…) becomes an MSL brace initializer, and a variable colliding with an MSL
// keyword (a bokeh kernel named `kernel`) is renamed so Metal doesn't read it as the compute keyword.
let kernelShader = """
const vec2 kernel[3] = vec2[3](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0));
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
vec3 gather(vec2 uv) {
    vec3 c = vec3(0.0);
    for (int i = 0; i < 3; i++) { c += texSample2D(g_Texture0, uv + kernel[i]).rgb; }
    return c;
}
void main() { gl_FragColor = vec4(gather(v_TexCoord.xy), 1.0); }
"""
let kernelMSL = WEShaderTranspiler.fragmentToMSL(kernelShader)
Check.that("a GLSL array constructor becomes an MSL brace initializer", kernelMSL.contains("= {float2"))
Check.that("a variable colliding with an MSL keyword is renamed", kernelMSL.contains("we_id_kernel"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: kernelMSL, options: nil)
        Check.that("a shader with a 'kernel' array and array constructor compiles", true)
    } catch {
        print("──── MSL ────\n\(kernelMSL)\n─────────────")
        Check.that("a shader with a 'kernel' array and array constructor compiles", false)
    }
}

// MSL has no min(int, float) overload, so WE's `min(x, 1)` with a float x is ambiguous — promote the
// integer literal when a sibling is a presumed-float value. An all-integer min(2, 3), an int-variable
// call clamp(n, 0, n), and a nested min(min(v, 1), 5) must all behave correctly.
let promoteShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    float v = texSample2D(g_Texture0, v_TexCoord.xy).r;
    int n = 3;
    int idx = clamp(n, 0, n);
    float w = min(min(v, 1), 5);
    gl_FragColor = vec4(w, max(0, v), v * float(min(2, 3) + idx), v);
}
"""
let promoteMSL = WEShaderTranspiler.fragmentToMSL(promoteShader)
Check.that("an integer literal beside a float is promoted in max", promoteMSL.contains("max(0.0, v)"))
Check.that("an all-integer min keeps its integer type", promoteMSL.contains("min(2, 3)"))
Check.that("a clamp on int-declared variables is not promoted", promoteMSL.contains("clamp(n, 0, n)"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: promoteMSL, options: nil)   // nested min + the int-var clamp must both type-check
        Check.that("a shader mixing int literals and floats in min/max/clamp compiles", true)
    } catch {
        print("──── MSL ────\n\(promoteMSL)\n─────────────")
        Check.that("a shader mixing int literals and floats in min/max/clamp compiles", false)
    }
}

// The promotion and array-constructor rewrites resume forward from each edit (linear time), so a 3-deep
// nest and successive constructors must still all be reached. A missed nested promotion would leave a
// min(float, int) that MSL rejects, so the compile check alone proves every level was promoted.
let nestedShader = """
varying vec4 v_TexCoord;
void main() {
    float x = v_TexCoord.x;
    float y = min(min(min(x, 1), 2), 3);
    vec2 a[2] = vec2[2](vec2(0.0), vec2(1.0));
    vec2 b[2] = vec2[2](vec2(2.0), vec2(3.0));
    gl_FragColor = vec4(y + a[0].x + b[1].y, 0.0, 0.0, 1.0);
}
"""
let nestedMSL = WEShaderTranspiler.fragmentToMSL(nestedShader)
Check.that("each successive array constructor becomes a brace initializer", nestedMSL.components(separatedBy: "= {float2").count == 3)
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: nestedMSL, options: nil)
        Check.that("a 3-deep nested promotion and successive array constructors compile", true)
    } catch {
        print("──── MSL ────\n\(nestedMSL)\n─────────────")
        Check.that("a 3-deep nested promotion and successive array constructors compile", false)
    }
}

// GLSL parameter direction qualifiers have no MSL spelling: `out`/`inout T x` becomes a `thread T&`
// reference (the caller's lvalue receives the write), and an explicit `in T x` drops to MSL's default.
// Exercised by a pure helper (emitted as a free function, like the lens shaders' computeUV) and a
// global-touching one (hosted as a lambda inside main).
let inoutShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_Amount;
void computeUV(in vec2 coord, in float scale, out vec2 uv, out vec2 uv2) {
    uv = coord * scale;
    uv2 = coord * (scale + 0.1);
}
void accumulate(in vec2 uv, inout vec3 acc) { acc += texSample2D(g_Texture0, uv).rgb * g_Amount; }
void main() {
    vec2 uv; vec2 uv2;
    computeUV(v_TexCoord.xy, 1.2, uv, uv2);
    vec3 acc = vec3(0.0);
    accumulate(uv, acc);
    accumulate(uv2, acc);
    gl_FragColor = vec4(acc, 1.0);
}
"""
let inoutMSL = WEShaderTranspiler.fragmentToMSL(inoutShader)
Check.that("an out parameter on a free helper becomes a thread reference", inoutMSL.contains("thread float2& uv"))
Check.that("an in parameter drops to MSL's default", inoutMSL.contains("computeUV(float2 coord"))
Check.that("an inout parameter on a hosted lambda becomes a thread reference", inoutMSL.contains("thread float3& acc"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: inoutMSL, options: nil)
        Check.that("a shader using in/out/inout parameter qualifiers compiles", true)
    } catch {
        print("──── MSL ────\n\(inoutMSL)\n─────────────")
        Check.that("a shader using in/out/inout parameter qualifiers compiles", false)
    }
}

// A file-scope const whose initializer reads a uniform can't be an MSL `constant` (that address space
// can't see the uniform buffer); it's hoisted into main as a qualified local, ahead of any lambda that
// captures it. A const with a compile-time initializer still emits at file scope.
let uniformConstShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float u_Feather;
const float FEATHER = u_Feather * 0.5;
const float GAMMA = 2.2;
void main() {
    float edge = smoothstep(0.5 - FEATHER, 0.5 + FEATHER, v_TexCoord.x);
    vec3 c = pow(texSample2D(g_Texture0, v_TexCoord.xy).rgb, vec3(GAMMA));
    gl_FragColor = vec4(c * edge, 1.0);
}
"""
let uniformConstMSL = WEShaderTranspiler.fragmentToMSL(uniformConstShader)
Check.that("a uniform-derived const is hoisted into main as a qualified local", uniformConstMSL.contains("float FEATHER = u.u_Feather * 0.5;"))
Check.that("a uniform-derived const is not emitted at file scope", !uniformConstMSL.contains("constant float FEATHER"))
Check.that("a compile-time const still emits at file scope", uniformConstMSL.contains("constant float GAMMA = 2.2;"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: uniformConstMSL, options: nil)
        Check.that("a shader with a uniform-derived file-scope const compiles", true)
    } catch {
        print("──── MSL ────\n\(uniformConstMSL)\n─────────────")
        Check.that("a shader with a uniform-derived file-scope const compiles", false)
    }
}

// A uniform-derived const can feed ANOTHER const (transitive) and can be an array; both must be hoisted
// into main, not emitted in the `constant` address space where the uniform / main-local isn't visible.
let chainedConstShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float u_Feather;
const float A = u_Feather * 2.0;
const float AB = A * 3.0;
const float arr[2] = float[2](u_Feather, 2.0);
float useArr(float t) { return arr[0] * t; }
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * (A + AB + useArr(u_Feather));
}
"""
let chainedConstMSL = WEShaderTranspiler.fragmentToMSL(chainedConstShader)
Check.that("a transitively uniform-derived const is hoisted into main", chainedConstMSL.contains("float AB = A * 3.0;"))
Check.that("a transitive uniform-derived const is not emitted at file scope", !chainedConstMSL.contains("constant float AB"))
Check.that("a uniform-derived const array is hoisted, not left at file scope", !chainedConstMSL.contains("constant float arr"))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: chainedConstMSL, options: nil)
        Check.that("a shader with chained and array uniform-derived consts compiles", true)
    } catch {
        print("──── MSL ────\n\(chainedConstMSL)\n─────────────")
        Check.that("a shader with chained and array uniform-derived consts compiles", false)
    }
}

// rewriteMul and rewriteTexLod resume past each rewrite (linear time); a nested mul and a texSample2DLod
// must still be fully rewritten (none left), and the result must compile.
let nestedMulShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
uniform mat3 g_M;
void main() {
    vec3 p = mul(mul(g_M, vec3(v_TexCoord.xy, 1.0)), g_M);
    gl_FragColor = texSample2DLod(g_Texture0, p.xy, 0.0);
}
"""
let nestedMulMSL = WEShaderTranspiler.fragmentToMSL(nestedMulShader)
Check.that("a nested mul is fully rewritten", !nestedMulMSL.contains("mul("))
Check.that("texSample2DLod is rewritten to a sample call", !nestedMulMSL.contains("texSample2DLod("))
if let device = MTLCreateSystemDefaultDevice() {
    do {
        _ = try device.makeLibrary(source: nestedMulMSL, options: nil)
        Check.that("a shader with nested mul and texSample2DLod compiles", true)
    } catch {
        print("──── MSL ────\n\(nestedMulMSL)\n─────────────")
        Check.that("a shader with nested mul and texSample2DLod compiles", false)
    }
}

Check.section("ShaderPreprocessor")
let conditional = "a\n#if MASK == 1\nb\n#else\nc\n#endif\nd"
Check.that("keeps the active #if branch", ShaderPreprocessor.resolve(conditional, combos: ["MASK": 1]) == "a\nb\nd")
Check.that("keeps the #else when the #if is inactive", ShaderPreprocessor.resolve(conditional, combos: ["MASK": 0]) == "a\nc\nd")
Check.that("a missing combo reads as 0", ShaderPreprocessor.resolve(conditional, combos: [:]) == "a\nc\nd")
Check.that("#ifdef follows definedness, not value", ShaderPreprocessor.resolve("#ifdef X\ny\n#endif", combos: ["X": 0]) == "y")
// A #define makes its name defined for #ifdef/#ifndef/defined() regardless of its value parsing as an int —
// a valueless flag, a function-like macro, and a float-valued macro are all "defined" (C semantics).
Check.that("a valueless #define is seen by #ifdef", ShaderPreprocessor.resolve("#define HQ\n#ifdef HQ\ny\n#endif", combos: [:]) == "y")
Check.that("a valueless #define is seen by defined()", ShaderPreprocessor.resolve("#define FEATURE\n#if defined(FEATURE)\ny\n#else\nn\n#endif", combos: [:]) == "y")
Check.that("a function-like macro is seen by defined()", ShaderPreprocessor.resolve("#define BLUR(x) ((x)*2.0)\n#if defined(BLUR)\ny\n#else\nn\n#endif", combos: [:]) == "y")
Check.that("a float-valued #define makes #ifndef false", ShaderPreprocessor.resolve("#define DEG2RAD 0.01745\n#ifndef DEG2RAD\ny\n#else\nn\n#endif", combos: [:]) == "n")
// The ! prefix negates a whole sub-expression: !defined(X) must be the inverse of defined(X), not a no-op.
Check.that("!defined(NAME) is false when NAME is defined (else branch taken)",
           ShaderPreprocessor.resolve("#define F\n#if !defined(F)\nx\n#else\ny\n#endif", combos: [:]) == "y")
Check.that("!defined(NAME) is true when NAME is undefined (then branch taken)",
           ShaderPreprocessor.resolve("#if !defined(F)\nx\n#else\ny\n#endif", combos: [:]) == "x")
// Regression: WE ships CRLF. Swift treats "\r\n" as one grapheme, so a naive split(separator:"\n")
// never matches it and the whole shader collapses to one line — emptying every transpiled body.
Check.that("normalises CRLF before resolving conditionals",
           ShaderPreprocessor.resolve("a\r\n#if MASK == 1\r\nb\r\n#endif\r\nc", combos: ["MASK": 0]) == "a\nc")
// Logical and relational operators in #if must be evaluated, not silently treated as a single unknown
// name (which drops the branch).
Check.that("evaluates && (both true keeps the branch)", ShaderPreprocessor.resolve("#if A && B\nx\n#endif", combos: ["A": 1, "B": 1]) == "x")
Check.that("evaluates && (one false drops the branch)", ShaderPreprocessor.resolve("#if A && B\nx\n#endif", combos: ["A": 1, "B": 0]) == "")
Check.that("evaluates ||", ShaderPreprocessor.resolve("#if A || B\nx\n#endif", combos: ["A": 0, "B": 1]) == "x")
Check.that("evaluates a > comparison", ShaderPreprocessor.resolve("#if QUALITY > 2\nx\n#endif", combos: ["QUALITY": 3]) == "x")
Check.that("evaluates unary ! and parentheses", ShaderPreprocessor.resolve("#if !(MASK)\nx\n#endif", combos: ["MASK": 0]) == "x")
Check.that("evaluates C-style defined(NAME)", ShaderPreprocessor.resolve("#if defined(X)\ny\n#endif", combos: ["X": 0]) == "y")
// Arithmetic / bitwise operands must be evaluated, not read as one unknown name (which silently drops the branch).
Check.that("evaluates additive arithmetic", ShaderPreprocessor.resolve("#if A + 1 == 2\nx\n#endif", combos: ["A": 1]) == "x")
Check.that("evaluates a bitwise & (set bit keeps the branch)", ShaderPreprocessor.resolve("#if FLAGS & 2\nx\n#endif", combos: ["FLAGS": 6]) == "x")
Check.that("a zero bitwise & drops the branch", ShaderPreprocessor.resolve("#if FLAGS & 2\nx\n#endif", combos: ["FLAGS": 1]) == "")
Check.that("multiplication binds tighter than ==", ShaderPreprocessor.resolve("#if A * 2 == 4\nx\n#endif", combos: ["A": 2]) == "x")
// A shift operator (<< / >>) must not be mis-read as a single < / > comparison: one bracket would split the
// condition and mis-evaluate the branch. WE leaves shifts in a #if unevaluated (an unknown name -> 0), so the
// branch drops. Both combos below would WRONGLY keep the branch under the old one-bracket split.
Check.that("a << shift is left unevaluated, not split as a < comparison",
           ShaderPreprocessor.resolve("#if A << B\nx\n#endif", combos: ["A": 0, "B": 1]) == "")
Check.that("a >> shift is left unevaluated, not split as a > comparison",
           ShaderPreprocessor.resolve("#if A >> B\nx\n#endif", combos: ["A": 1, "B": 0]) == "")
// Regression: a genuine single < comparison still evaluates after the shift guard.
Check.that("a real < comparison still evaluates", ShaderPreprocessor.resolve("#if A < 2\nx\n#endif", combos: ["A": 1]) == "x")
// Regression: WE's effect shaders annotate combo branches inline, e.g. `#if TYPE == 4 // Cutout square`.
// A trailing // comment must be stripped before the condition is evaluated (as GLSL/C do). Leaving it in
// makes the right-hand side unparseable, so the comparison silently reads as `… == 0` and EVERY branch
// is mis-taken — frame_builder then emits a `float offset` from every TYPE block at once and MSL rejects
// the redefinitions. Pin both the `==` form and a #ifdef with a trailing comment.
Check.that("strips a trailing // comment before evaluating #if (inactive branch dropped)",
           ShaderPreprocessor.resolve("#if TYPE == 4 // Cutout\nx\n#endif", combos: ["TYPE": 0]) == "")
Check.that("strips a trailing // comment before evaluating #if (active branch kept)",
           ShaderPreprocessor.resolve("#if TYPE == 4 // Cutout\nx\n#endif", combos: ["TYPE": 4]) == "x")
Check.that("strips a trailing // comment on #elif",
           ShaderPreprocessor.resolve("#if A == 1 // one\np\n#elif A == 2 // two\nq\n#endif", combos: ["A": 2]) == "q")
Check.that("strips a trailing // comment on #ifdef",
           ShaderPreprocessor.resolve("#ifdef HQ // high quality\ny\n#endif", combos: ["HQ": 0]) == "y")
// Object-like `#define NAME value` is substituted into the lines after it (the WE headers lean on this:
// `#define endGamma 2.2`). It only takes effect from its definition downward, matches whole words, and
// an integer value also feeds a later `#if`. Function-like macros are left for the transpiler.
Check.that("substitutes an object-like #define into the body",
           ShaderPreprocessor.resolve("#define endGamma 2.2\ny = endGamma;", combos: [:]) == "y = 2.2;")
Check.that("a #define only applies below its definition",
           ShaderPreprocessor.resolve("a = K;\n#define K 9\nb = K;", combos: [:]) == "a = K;\nb = 9;")
Check.that("an integer #define is visible to a later #if",
           ShaderPreprocessor.resolve("#define R 3\n#if R == 3\nx\n#endif", combos: [:]) == "x")
Check.that("a #define substitutes whole words only",
           ShaderPreprocessor.resolve("#define A 1\nApple AB A", combos: [:]) == "Apple AB 1")
// Function-like macros expand at their call sites, parenthesising arguments so precedence is preserved
// — WE's blur headers inject the framebuffer this way (`#define blur13a(uv,s) _blur13a(g_Texture0,uv,s)`).
let funcMacroExpanded = ShaderPreprocessor.resolve("#define SQR(x) x * x\ng = SQR(a + b);", combos: [:])
Check.that("expands a function-like macro and parenthesises its argument",
           funcMacroExpanded.contains("(a + b) * (a + b)") && !funcMacroExpanded.contains("SQR"))
let twoArg = ShaderPreprocessor.resolve("#define MIX(a, b) a + b\nv = MIX(p, q);", combos: [:])
Check.that("a two-argument function-like macro substitutes both parameters",
           twoArg.contains("(p)") && twoArg.contains("(q)") && !twoArg.contains("MIX"))
Check.that("a function-like macro call with nested parens parses its arguments",
           ShaderPreprocessor.resolve("#define F(x) x\nv = F(g(1, 2));", combos: [:]).contains("(g(1, 2))"))
// #include resolution — the helpers WE shaders call live in engine headers that aren't packed in the
// wallpaper, so the preprocessor splices them from a header map (recursively, cycle-safe).
Check.that("splices an included header's source",
           ShaderPreprocessor.resolve("#include \"h\"\ny = k();", combos: [:], includes: ["h": "float k() { return 1.0; }"]).contains("float k()"))
Check.that("an included #define reaches the includer's #if",
           ShaderPreprocessor.resolve("#include \"k\"\n#if K == 2\nx\n#endif", combos: [:], includes: ["k": "#define K 2"]) == "x")
Check.that("an unknown #include is left in place",
           ShaderPreprocessor.resolve("#include \"missing\"\ny", combos: [:], includes: [:]).contains("y"))
Check.that("nested includes resolve",
           ShaderPreprocessor.resolve("#include \"a\"", combos: [:], includes: ["a": "#include \"b\"", "b": "deep"]) == "deep")
Check.that("a cyclic include terminates",
           ShaderPreprocessor.resolve("#include \"a\"\ntail", combos: [:], includes: ["a": "#include \"a\"\nx"]).contains("tail"))
// A trailing comment on a #define must not be captured into the macro value/body — it would be
// substituted mid-statement, and the later comment-stripper would then eat the following tokens.
Check.that("an object macro drops a trailing line comment from its value",
           ShaderPreprocessor.resolve("#define DEG2RAD 0.01745 // 2*PI/360\na = x * DEG2RAD;", combos: [:]) == "a = x * 0.01745;")
Check.that("an object macro drops a trailing block comment so an int value still seeds a #if",
           ShaderPreprocessor.resolve("#define LEVELS 3 /* count */\n#if LEVELS == 3\nx\n#endif", combos: [:]) == "x")
Check.that("a function macro drops a trailing comment from its body",
           ShaderPreprocessor.resolve("#define SQR(x) (x)*(x) // square\nv = SQR(a);", combos: [:]).contains("((a))*((a))"))
// A reduplicating macro must not amplify memory without bound on crafted (untrusted) shader input.
let macroBomb = ShaderPreprocessor.resolve("#define A(x) x x\n#define B(x) A(A(x))\n#define C(x) B(B(x))\n#define D(x) C(C(x))\nv = D(D(D(z)));", combos: [:])
Check.that("a reduplicating macro expansion stays bounded", macroBomb.utf8.count < 5_000_000)
// An object-like doubling macro amplifies WITHIN a single pass (the inner replace loop), so that loop must
// be size-bounded too, not only the outer pass loop.
let objectBomb = ShaderPreprocessor.resolve("#define X X X\nv = X;", combos: [:])
Check.that("an object-macro reduplication stays bounded", objectBomb.utf8.count < 5_000_000)
// A different shape: ONE macro whose value is large, used many times on a line — a single substitution
// expands every occurrence in one allocation, so the projected-size guard must stop it before it balloons.
let bigValue = String(repeating: "X", count: 200_000)
let singlePassBomb = ShaderPreprocessor.resolve("#define BIG \(bigValue)\ncode \(String(repeating: "BIG ", count: 100));", combos: [:])
Check.that("a large macro value used many times expands within bounds", singlePassBomb.utf8.count < 2_000_000)
// A crafted shader can nest #if hundreds deep; the conditional resolver is stack-based (a frame array), so
// it must handle this without overflowing the call stack. Reaching the assertion proves it returned; with
// the combo true every branch is active, so the guarded body survives.
let deepIf = String(repeating: "#if A\n", count: 2000) + "kept\n" + String(repeating: "#endif\n", count: 2000)
Check.that("deeply nested #if resolves without crashing", ShaderPreprocessor.resolve(deepIf, combos: ["A": 1]).contains("kept"))
// A single #if condition with thousands of nested parens drives the RECURSIVE evaluator (not the frame
// stack); it must bail at the depth cap, not overflow the call stack. (~25k parens SIGSEGVs without the cap.)
let deepParens = "#if " + String(repeating: "(", count: 100_000) + "0" + String(repeating: ")", count: 100_000) + "\nkept\n#endif"
Check.that("a deeply parenthesised #if condition doesn't overflow the stack",
           !ShaderPreprocessor.resolve(deepParens, combos: [:]).contains("kept"))   // over-deep → 0 → branch dropped
// A legitimately nested condition still evaluates correctly under the cap.
Check.that("a normally nested condition still evaluates", ShaderPreprocessor.resolve("#if !((A))\nx\n#endif", combos: ["A": 0]) == "x")
// Unbalanced conditionals (a stray #endif / #else with no open #if) must be tolerated, not trap.
Check.that("a stray #endif is tolerated", ShaderPreprocessor.resolve("#endif\nkept", combos: [:]).contains("kept"))
// An out-of-range numeric default in a uniform's JSON annotation must not trap String(Int(_:)).
let bigDefault = ShaderUniforms.parse("uniform float g_X; // {\"default\":1e20}")
Check.that("an out-of-range numeric default parses without trapping", bigDefault.first?.defaultValue != nil)
let crlfShader = "varying vec4 v_TexCoord;\r\nuniform sampler2D g_Texture0;\r\nvoid main() {\r\n    gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy);\r\n}\r\n"
Check.that("a CRLF shader transpiles to a non-empty body",
           WEShaderTranspiler.fragmentToMSL(crlfShader).contains("g_Texture0.sample("))

Check.section("UniformPacker")
let packed = UniformPacker.pack([
    ShaderUniform(type: "float", name: "g_A", material: "a"),
    ShaderUniform(type: "vec3", name: "g_B", material: "b"),
], values: ["a": "0.5", "b": "1 2 3"])
Check.that("packs to the MSL-aligned struct size (4 + pad-to-16 + 16 = 32)", packed.count == 32)
let packedFloats = packed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
Check.that("scalar lands at offset 0", packedFloats[0] == 0.5)
Check.that("vec3 is aligned to offset 16 (float index 4)",
           packedFloats[4] == 1 && packedFloats[5] == 2 && packedFloats[6] == 3)
let defaulted = UniformPacker.pack([ShaderUniform(type: "float", name: "g_X", material: "x", defaultValue: "0.25")], values: [:])
Check.that("falls back to the default when no value is given",
           defaulted.withUnsafeBytes { $0.bindMemory(to: Float.self)[0] } == 0.25)
// A mat3 uniform is three float3 columns each padded to 16 bytes (48 total) — packing it as 9 contiguous
// floats would desync every uniform after it.
let mat3 = UniformPacker.pack([ShaderUniform(type: "mat3", name: "g_M", material: "m")], values: ["m": "1 2 3 4 5 6 7 8 9"])
let mat3Floats = mat3.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
Check.that("mat3 packs to 48 bytes with per-column padding",
           mat3.count == 48 && mat3Floats[3] == 0 && mat3Floats[4] == 4 && mat3Floats[8] == 7)
// mat2 is two contiguous float2 columns (16 bytes, no per-column padding); a following uniform must land at
// that 16-byte stride or it reads the matrix's tail. mat4 is 16 contiguous floats (64 bytes).
let mat2Packed = UniformPacker.pack([
    ShaderUniform(type: "mat2", name: "g_M2", material: "m"),
    ShaderUniform(type: "float", name: "g_After", material: "a"),
], values: ["m": "1 2 3 4", "a": "9"])
let mat2Floats = mat2Packed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
Check.that("mat2 packs 4 contiguous floats with the next uniform at its 16-byte stride",
           mat2Floats[0] == 1 && mat2Floats[1] == 2 && mat2Floats[2] == 3 && mat2Floats[3] == 4 && mat2Floats[4] == 9)
let mat4Packed = UniformPacker.pack([ShaderUniform(type: "mat4", name: "g_M4", material: "m")],
                                    values: ["m": "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16"])
let mat4Floats = mat4Packed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
Check.that("mat4 packs to 64 contiguous bytes", mat4Packed.count == 64 && mat4Floats[0] == 1 && mat4Floats[15] == 16)
// The override path (how the renderer injects an animated g_Time) takes precedence over values/default.
let overridden = UniformPacker.pack([ShaderUniform(type: "float", name: "g_Time", material: "t", defaultValue: "0")],
                                    values: ["t": "1"], overrides: ["g_Time": [5]])
Check.that("an override replaces the value by uniform name",
           overridden.withUnsafeBytes { $0.bindMemory(to: Float.self)[0] } == 5)

// Array uniforms (audio spectra: `uniform float g_AudioSpectrum16Left[16];`). The parser must capture the
// size, the transpiler must emit a `float[N]` member, and the packer must lay it out as N tightly-packed
// floats (MSL packs a scalar array at 4-byte stride) so a renderer override of N values reaches the shader.
let audioDecl = ShaderUniforms.parse("uniform float g_AudioSpectrum16Left[16];").first
Check.that("parses an array uniform's element count", audioDecl?.arrayCount == 16)
Check.that("a plain uniform has no array count", ShaderUniforms.parse("uniform float g_X;").first?.arrayCount == nil)
let arrMSL = WEShaderTranspiler.fragmentToMSL("""
uniform sampler2D g_Texture0;
uniform float g_AudioSpectrum16Left[16];
varying vec4 v_TexCoord;
void main() { gl_FragColor = float4(g_AudioSpectrum16Left[3]); }
""")
Check.that("emits a float[N] array member in the Uniforms struct", arrMSL.contains("float g_AudioSpectrum16Left[16];"))
if let device = MTLCreateSystemDefaultDevice() {
    Check.that("an indexed array uniform compiles via Metal", (try? device.makeLibrary(source: arrMSL, options: nil))?.makeFunction(name: "we_fragment") != nil)
}
var spectrum = [Float](repeating: 0, count: 16); spectrum[3] = 0.75
let packedArr = UniformPacker.pack([ShaderUniform(type: "float", name: "g_AudioSpectrum16Left", arrayCount: 16)],
                                   values: [:], overrides: ["g_AudioSpectrum16Left": spectrum])
Check.that("packs a float[16] array uniform to 64 contiguous bytes", packedArr.count == 64)
Check.that("array element values land at their float index",
           packedArr.withUnsafeBytes { $0.bindMemory(to: Float.self)[3] } == 0.75)

// A hostile shader can declare an absurd array size. Packing it must stay bounded — never overflow the
// `components * count` arithmetic or attempt a multi-gigabyte allocation — by capping the element count.
let cap = WEShaderTranspiler.maxArrayElements
let hugeArray = UniformPacker.pack([ShaderUniform(type: "float", name: "g_Big", arrayCount: 2_000_000_000)], values: [:])
Check.that("a huge float[N] count is capped, not allocated wholesale", hugeArray.count == cap * 4)
let maxArray = UniformPacker.pack([ShaderUniform(type: "vec4", name: "g_Max", arrayCount: Int.max)], values: [:])
Check.that("an Int.max array count packs without trapping the multiply", maxArray.count == cap * 16)

// The packer's array cap MUST equal the transpiler's struct-member cap, or a uniform after an over-long
// array lands at a different byte offset in the packed data than in the emitted struct and reads garbage.
// Verify directly: an over-long g_Spectrum followed by g_Tint — the packed g_Tint must sit at exactly the
// offset the emitted MSL struct declares (4 * cap, already 16-aligned).
let layoutFrag = "uniform float g_Spectrum[\(cap + 976)]; // {\"material\":\"s\"}\nuniform vec4 g_Tint; // {\"material\":\"t\"}\nvarying vec4 v_TexCoord;\nvoid main() { gl_FragColor = g_Tint * g_Spectrum[0]; }"
let layoutMSL = WEShaderTranspiler.fragmentToMSL(layoutFrag)
Check.that("an over-long array clamps to the shared cap in the struct", layoutMSL.contains("float g_Spectrum[\(cap)]"))
let layoutUniforms = ShaderUniforms.parse(layoutFrag).filter { !$0.type.hasPrefix("sampler") }
let layoutPacked = UniformPacker.pack(layoutUniforms, values: ["t": "0.1 0.2 0.3 0.4"])
Check.that("the packed uniform after the array sits at the struct's offset (caps agree)",
           layoutPacked.count == cap * 4 + 16
           && layoutPacked.withUnsafeBytes { $0.bindMemory(to: Float.self)[cap] } == 0.1)

runDiagnosticsChecks()
runAuditFixChecks()

Check.summarize()

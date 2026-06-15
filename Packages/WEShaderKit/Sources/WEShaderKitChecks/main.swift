// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room verification of the WE shader uniform/annotation extractor against a shader
// in the real WE dialect (CLT-only equivalent of unit tests).
import Foundation
import Metal
import WEShaderKit

// Dev mode: a .frag file lists its uniforms; a directory measures transpiler coverage (how many real
// shaders transpile to MSL that Metal accepts).
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
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white"}
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

// WE shaders assume math.h constants and helpers from their unshipped common headers; the prelude
// supplies them. A shader using M_PI_2 and rotateVec2 must transpile to MSL that Metal accepts.
let preludeShader = """
varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, rotateVec2(v_TexCoord.xy, M_PI_2)); }
"""
if let device = MTLCreateSystemDefaultDevice() {
    let preludeMSL = WEShaderTranspiler.fragmentToMSL(preludeShader)
    Check.that("prelude compiles a shader using M_PI_2 and rotateVec2",
               (try? device.makeLibrary(source: preludeMSL, options: nil)) != nil)
}

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

Check.section("ShaderPreprocessor")
let conditional = "a\n#if MASK == 1\nb\n#else\nc\n#endif\nd"
Check.that("keeps the active #if branch", ShaderPreprocessor.resolve(conditional, combos: ["MASK": 1]) == "a\nb\nd")
Check.that("keeps the #else when the #if is inactive", ShaderPreprocessor.resolve(conditional, combos: ["MASK": 0]) == "a\nc\nd")
Check.that("a missing combo reads as 0", ShaderPreprocessor.resolve(conditional, combos: [:]) == "a\nc\nd")
Check.that("#ifdef follows definedness, not value", ShaderPreprocessor.resolve("#ifdef X\ny\n#endif", combos: ["X": 0]) == "y")
// Regression: WE ships CRLF. Swift treats "\r\n" as one grapheme, so a naive split(separator:"\n")
// never matches it and the whole shader collapses to one line — emptying every transpiled body.
Check.that("normalises CRLF before resolving conditionals",
           ShaderPreprocessor.resolve("a\r\n#if MASK == 1\r\nb\r\n#endif\r\nc", combos: ["MASK": 0]) == "a\nc")
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

Check.summarize()

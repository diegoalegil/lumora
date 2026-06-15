// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Source-to-source transpiler from Wallpaper Engine's GLSL-ish fragment-shader
// dialect to Metal Shading Language, derived from the shader bytes in the user's own packages and the
// public WE shader docs (no GPL translator consulted). First cut: the common structure (varyings, g_*
// uniforms, texSample2D, gl_FragColor, the standard intrinsics). The output should be compiled with
// `device.makeLibrary(source:)` to confirm it is valid before use; unsupported constructs (#if combos,
// includes, multiple render targets) simply won't compile yet.
import Foundation

public enum WEShaderTranspiler {
    /// Transpile a WE-dialect fragment shader to an MSL source string with a fragment function named
    /// `functionName`. Reuses `ShaderUniforms` to bind textures and a uniform buffer.
    public static func fragmentToMSL(_ source: String, functionName: String = "we_fragment",
                                     combos: [String: Int] = [:]) -> String {
        let resolved = ShaderPreprocessor.resolve(source, combos: combos)
        let uniforms = ShaderUniforms.parse(resolved)
        let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
        let scalars = uniforms.filter { !$0.type.hasPrefix("sampler") }
        let varyings = parseDeclarations(resolved, keyword: "varying")

        var body = mainBody(of: resolved)
        body = rewriteIntrinsics(body)
        body = rewriteTypes(body)
        // Qualify references: varyings come from stage_in, scalar uniforms from the uniform buffer.
        for varying in varyings { body = qualify(body, name: varying.name, with: "in.\(varying.name)") }
        for uniform in scalars { body = qualify(body, name: uniform.name, with: "u.\(uniform.name)") }
        // gl_FragColor → a local we collect and return.
        body = qualify(body, name: "gl_FragColor", with: "_fragColor")

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + WEShaderPrelude.msl

        msl += "struct VaryingIn {\n"
        for (index, varying) in varyings.enumerated() {
            msl += "    \(mslType(varying.type)) \(varying.name) [[user(locn\(index))]];\n"
        }
        msl += "};\n\n"

        if !scalars.isEmpty {
            msl += "struct Uniforms {\n"
            for uniform in scalars { msl += "    \(mslType(uniform.type)) \(uniform.name);\n" }
            msl += "};\n\n"
        }

        msl += "fragment float4 \(functionName)(VaryingIn in [[stage_in]]"
        if !scalars.isEmpty { msl += ",\n    constant Uniforms& u [[buffer(0)]]" }
        for (index, sampler) in samplers.enumerated() {
            let textureType = sampler.type == "sampler2DComparison" ? "depth2d<float>" : "texture2d<float>"
            msl += ",\n    \(textureType) \(sampler.name) [[texture(\(index))]]"
            msl += ",\n    sampler \(sampler.name)_smp [[sampler(\(index))]]"
        }
        msl += ") {\n    float4 _fragColor = float4(0.0);\n"
        msl += body
        msl += "\n    return _fragColor;\n}\n"
        return msl
    }

    /// Transpile a WE-dialect vertex shader to MSL with a vertex function named `functionName`.
    /// Attributes become a stage_in struct, varyings the output struct (carrying `[[position]]`), and
    /// `gl_Position` the output position.
    public static func vertexToMSL(_ source: String, functionName: String = "we_vertex",
                                   combos: [String: Int] = [:]) -> String {
        let resolved = ShaderPreprocessor.resolve(source, combos: combos)
        let uniforms = ShaderUniforms.parse(resolved)
        let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
        let scalars = uniforms.filter { !$0.type.hasPrefix("sampler") }
        let attributes = parseDeclarations(resolved, keyword: "attribute")
        let varyings = parseDeclarations(resolved, keyword: "varying")

        var body = mainBody(of: resolved)
        body = rewriteIntrinsics(body)
        body = rewriteTypes(body)
        for attribute in attributes { body = qualify(body, name: attribute.name, with: "in.\(attribute.name)") }
        for varying in varyings { body = qualify(body, name: varying.name, with: "out.\(varying.name)") }
        for uniform in scalars { body = qualify(body, name: uniform.name, with: "u.\(uniform.name)") }
        body = qualify(body, name: "gl_Position", with: "out.position")

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + WEShaderPrelude.msl
        msl += "struct VertexIn {\n"
        for (index, attribute) in attributes.enumerated() {
            msl += "    \(mslType(attribute.type)) \(attribute.name) [[attribute(\(index))]];\n"
        }
        msl += "};\n\nstruct VertexOut {\n    float4 position [[position]];\n"
        for (index, varying) in varyings.enumerated() {
            msl += "    \(mslType(varying.type)) \(varying.name) [[user(locn\(index))]];\n"
        }
        msl += "};\n\n"
        if !scalars.isEmpty {
            msl += "struct Uniforms {\n"
            for uniform in scalars { msl += "    \(mslType(uniform.type)) \(uniform.name);\n" }
            msl += "};\n\n"
        }
        msl += "vertex VertexOut \(functionName)(VertexIn in [[stage_in]]"
        if !scalars.isEmpty { msl += ",\n    constant Uniforms& u [[buffer(0)]]" }
        for (index, sampler) in samplers.enumerated() {
            let textureType = sampler.type == "sampler2DComparison" ? "depth2d<float>" : "texture2d<float>"
            msl += ",\n    \(textureType) \(sampler.name) [[texture(\(index))]]"
            msl += ",\n    sampler \(sampler.name)_smp [[sampler(\(index))]]"
        }
        msl += ") {\n    VertexOut out;\n"
        msl += body
        msl += "\n    return out;\n}\n"
        return msl
    }

    // MARK: - Pieces

    /// `<keyword> <type> <name>;` declarations (e.g. `varying`/`attribute`), de-duplicated by name.
    private static func parseDeclarations(_ source: String, keyword: String) -> [(type: String, name: String)] {
        var result: [(String, String)] = []
        var seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"^\s*\#(keyword)\s+(\w+)\s+(\w+)\s*;"#)
        source.enumerateLines { line, _ in
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: whole),
                  let t = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) else { return }
            let name = String(line[n])
            if seen.insert(name).inserted { result.append((String(line[t]), name)) }   // dedup repeats
        }
        return result
    }

    /// The contents of `void main() { … }` with comments and preprocessor lines stripped.
    private static func mainBody(of source: String) -> String {
        var cleaned = stripLineComments(source)
        cleaned = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        guard let openRange = cleaned.range(of: "void main"),
              let braceIndex = cleaned[openRange.upperBound...].firstIndex(of: "{") else { return "" }
        let afterBrace = cleaned.index(after: braceIndex)
        guard let closing = cleaned.lastIndex(of: "}") else { return String(cleaned[afterBrace...]) }
        return String(cleaned[afterBrace..<closing])
    }

    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private static func rewriteIntrinsics(_ body: String) -> String {
        var out = body
        // texSample2D(g_Tex, uv) → g_Tex.sample(g_Tex_smp, uv)
        let texCall = try! NSRegularExpression(pattern: #"texSample2D\(\s*(g_\w+)\s*,"#)
        out = texCall.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                               withTemplate: "$1.sample($1_smp,")
        out = rewriteMul(out)   // HLSL-style mul(a, b) → (a * b)
        for (glsl, msl) in [("frac", "fract"), ("mod", "fmod"), ("inversesqrt", "rsqrt")] {
            out = replaceWord(out, glsl, msl)
        }
        return out
    }

    /// Rewrite WE/HLSL `mul(a, b)` matrix products to Metal's `(a) * (b)`, matching balanced parens so
    /// nested calls and comma-bearing arguments survive.
    private static func rewriteMul(_ source: String) -> String {
        var s = source
        while let call = s.range(of: "mul(") {
            var depth = 1
            var comma: String.Index?
            var close: String.Index?
            var i = call.upperBound
            while i < s.endIndex {
                switch s[i] {
                case "(": depth += 1
                case ")": depth -= 1; if depth == 0 { close = i }
                case "," where depth == 1: if comma == nil { comma = i }
                default: break
                }
                if close != nil { break }
                i = s.index(after: i)
            }
            guard let commaIndex = comma, let closeIndex = close else { break }   // malformed — leave it
            let a = s[call.upperBound..<commaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let b = s[s.index(after: commaIndex)..<closeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            s.replaceSubrange(call.lowerBound...closeIndex, with: "((\(a)) * (\(b)))")
        }
        return s
    }

    private static func rewriteTypes(_ body: String) -> String {
        var out = body
        for (glsl, msl) in [("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
                            ("mat2", "float2x2"), ("mat3", "float3x3"), ("mat4", "float4x4"),
                            ("ivec2", "int2"), ("ivec3", "int3"), ("ivec4", "int4"),
                            // WE cast macros (their #define is stripped) → Metal constructors
                            ("CAST2", "float2"), ("CAST3", "float3"), ("CAST4", "float4"),
                            ("CAST2X2", "float2x2"), ("CAST3X3", "float3x3"), ("CAST4X4", "float4x4")] {
            out = replaceWord(out, glsl, msl)
        }
        return out
    }

    private static func mslType(_ type: String) -> String {
        switch type {
        case "vec2": return "float2"; case "vec3": return "float3"; case "vec4": return "float4"
        case "mat2": return "float2x2"; case "mat3": return "float3x3"; case "mat4": return "float4x4"
        default: return type
        }
    }

    private static func qualify(_ body: String, name: String, with replacement: String) -> String {
        replaceWord(body, name, replacement)
    }

    /// Replace whole-word occurrences of `word` (not as part of a larger identifier or after a `.`).
    private static func replaceWord(_ source: String, _ word: String, _ replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let regex = try! NSRegularExpression(pattern: "(?<![\\w.])\(escaped)(?![\\w])")
        return regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

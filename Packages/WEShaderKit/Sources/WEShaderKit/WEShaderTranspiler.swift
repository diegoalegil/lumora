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
    public static func fragmentToMSL(_ source: String, functionName: String = "we_fragment") -> String {
        let uniforms = ShaderUniforms.parse(source)
        let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
        let scalars = uniforms.filter { !$0.type.hasPrefix("sampler") }
        let varyings = parseVaryings(source)

        var body = mainBody(of: source)
        body = rewriteIntrinsics(body)
        body = rewriteTypes(body)
        // Qualify references: varyings come from stage_in, scalar uniforms from the uniform buffer.
        for varying in varyings { body = qualify(body, name: varying.name, with: "in.\(varying.name)") }
        for uniform in scalars { body = qualify(body, name: uniform.name, with: "u.\(uniform.name)") }
        // gl_FragColor → a local we collect and return.
        body = qualify(body, name: "gl_FragColor", with: "_fragColor")

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n"

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

    // MARK: - Pieces

    private static func parseVaryings(_ source: String) -> [(type: String, name: String)] {
        var result: [(String, String)] = []
        var seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"^\s*varying\s+(\w+)\s+(\w+)\s*;"#)
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
        for (glsl, msl) in [("frac", "fract"), ("mod", "fmod"), ("inversesqrt", "rsqrt")] {
            out = replaceWord(out, glsl, msl)
        }
        return out
    }

    private static func rewriteTypes(_ body: String) -> String {
        var out = body
        for (glsl, msl) in [("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
                            ("mat2", "float2x2"), ("mat3", "float3x3"), ("mat4", "float4x4"),
                            ("ivec2", "int2"), ("ivec3", "int3"), ("ivec4", "int4")] {
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

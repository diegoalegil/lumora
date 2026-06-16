// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Source-to-source transpiler from Wallpaper Engine's GLSL-ish fragment-shader
// dialect to Metal Shading Language, derived from the shader bytes in the user's own packages and the
// public WE shader docs (no GPL translator consulted). It rewrites the dialect's varyings, g_*/u_*
// uniforms, texSample2D, gl_FragColor and the standard intrinsics, resolves #if combos and includes,
// and prepends a prelude alongside the shader's own helper functions. The output is compiled with
// `device.makeLibrary(source:)`; a construct it doesn't model degrades to a no-op body rather than
// emitting invalid MSL, so an unsupported effect drops out instead of breaking the scene.
import Foundation

public enum WEShaderTranspiler {
    /// Transpile a WE-dialect fragment shader to an MSL source string with a fragment function named
    /// `functionName`. Reuses `ShaderUniforms` to bind textures and a uniform buffer.
    public static func fragmentToMSL(_ source: String, functionName: String = "we_fragment",
                                     combos: [String: Int] = [:]) -> String {
        let combos = ShaderPreprocessor.comboDefaults(source).merging(combos) { _, explicit in explicit }
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

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + comboConstants(combos)
            + WEShaderPrelude.msl + helperFunctions(of: resolved)

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
        let combos = ShaderPreprocessor.comboDefaults(source).merging(combos) { _, explicit in explicit }
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

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + comboConstants(combos)
            + WEShaderPrelude.msl + helperFunctions(of: resolved)
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

    /// Emit the selected combo values as `#define`s so code that uses a combo as a runtime value (e.g.
    /// `ApplyBlending(BLENDMODE, …)`) sees its integer — matching how WE compiles combos into the shader.
    private static func comboConstants(_ combos: [String: Int]) -> String {
        guard !combos.isEmpty else { return "" }
        return combos.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)\n" }.joined() + "\n"
    }

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

    /// The contents of `void main() { … }`, comments and preprocessor lines stripped. The body is
    /// brace-matched from `main`'s own `{` (via `topLevelBlocks`), not taken up to the file's last `}`,
    /// so a helper function defined *after* main isn't swallowed into the body — those are emitted
    /// separately by `helperFunctions`.
    private static func mainBody(of source: String) -> String {
        let cleaned = stripLineComments(stripBlockComments(source)).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        for (signature, body) in topLevelBlocks(cleaned) where functionName(of: signature) == "main" {
            return body
        }
        return ""
    }

    /// The function name in a top-level block signature — the identifier just before `(` — or "" for a
    /// struct or any non-function block.
    private static func functionName(of signature: String) -> String {
        guard let paren = signature.firstIndex(of: "(") else { return "" }
        return String(signature[..<paren].split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last ?? "")
    }

    /// The names of the functions the prelude already defines, so a shader's own copy isn't emitted on
    /// top of them (a redefinition).
    private static let preludeFunctionNames: Set<String> = {
        var names: Set<String> = []
        let regex = try! NSRegularExpression(pattern: #"inline\s+\w+\s+(\w+)\s*\("#)
        WEShaderPrelude.msl.enumerateLines { line, _ in
            let whole = NSRange(line.startIndex..., in: line)
            if let m = regex.firstMatch(in: line, range: whole), let r = Range(m.range(at: 1), in: line) {
                names.insert(String(line[r]))
            }
        }
        return names
    }()

    /// Emit the shader's own top-level helper functions and structs (everything but `main`) so code that
    /// calls them compiles. MSL free functions can't reach the fragment's globals, so a helper that
    /// references a uniform/sampler (g_*, u_*, texSample, gl_*) is skipped, as is one whose name the
    /// prelude already provides — both would otherwise fail to compile or redefine.
    private static func helperFunctions(of source: String) -> String {
        let cleaned = stripLineComments(stripBlockComments(source)).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        var out = ""
        for (signature, body) in topLevelBlocks(cleaned) {
            guard signature.contains("(") else {   // a struct or non-function block
                if signature.trimmingCharacters(in: .whitespaces).hasPrefix("struct") {
                    out += rewriteTypes(signature) + " {" + rewriteTypes(body) + "};\n"
                }
                continue
            }
            let name = functionName(of: signature)
            if name.isEmpty || name == "main" || preludeFunctionNames.contains(name) { continue }
            let text = signature + body
            if text.contains("g_") || text.contains("u_") || text.contains("texSample") || text.contains("gl_") { continue }
            out += rewriteTypes(rewriteIntrinsics(signature)) + " {" + rewriteTypes(rewriteIntrinsics(body)) + "}\n"
        }
        return out
    }

    /// Split a shader's top level into `(signature, body)` pairs — each `…{ … }` block (function or
    /// struct), with `signature` the text since the previous top-level `;`/`}`.
    private static func topLevelBlocks(_ source: String) -> [(signature: String, body: String)] {
        var blocks: [(String, String)] = []
        var depth = 0
        var segmentStart = source.startIndex
        var bodyStart: String.Index?
        var i = source.startIndex
        while i < source.endIndex {
            switch source[i] {
            case "{":
                if depth == 0 { bodyStart = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let start = bodyStart {
                    blocks.append((String(source[segmentStart..<start]).trimmingCharacters(in: .whitespacesAndNewlines),
                                   String(source[source.index(after: start)..<i])))
                    bodyStart = nil
                    segmentStart = source.index(after: i)
                }
            case ";" where depth == 0:
                segmentStart = source.index(after: i)
            default: break
            }
            i = source.index(after: i)
        }
        return blocks
    }

    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    /// Remove `//` line comments and `/* … */` block comments. `//` is matched first so a `//*` line
    /// comment isn't mistaken for a block opener (GLSL block comments don't nest); an unterminated block
    /// drops the rest, matching a compiler.
    private static func stripBlockComments(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
            } else if source[index...].hasPrefix("/*") {
                guard let end = source.range(of: "*/", range: index ..< source.endIndex) else { break }
                index = end.upperBound
                result.append(" ")   // a comment is whitespace — replace it with a space, not nothing,
                                     // so `vec3/* */color` doesn't fuse into the token `vec3color`
            } else {
                result.append(source[index])
                index = source.index(after: index)
            }
        }
        return result
    }

    private static func rewriteIntrinsics(_ body: String) -> String {
        var out = body
        out = rewriteTexLod(out)   // texSample2DLod(g_Tex, uv, lod) → g_Tex.sample(g_Tex_smp, uv, level(lod))
        // texSample2D(g_Tex, uv) → g_Tex.sample(g_Tex_smp, uv) — any sampler name (g_*, u_*).
        let texCall = try! NSRegularExpression(pattern: #"texSample2D\(\s*(\w+)\s*,"#)
        out = texCall.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                               withTemplate: "$1.sample($1_smp,")
        out = rewriteMul(out)   // HLSL-style mul(a, b) → (a * b)
        // (mod and two-arg atan are defined in the prelude — GLSL semantics differ from Metal's.)
        for (glsl, msl) in [("frac", "fract"), ("inversesqrt", "rsqrt"), ("lerp", "mix")] {
            out = replaceWord(out, glsl, msl)
        }
        return out
    }

    /// `texSample2DLod(g_Tex, uv, lod)` → `g_Tex.sample(g_Tex_smp, uv, level(lod))`, matching balanced
    /// parens so nested calls in the uv/lod arguments survive.
    private static func rewriteTexLod(_ source: String) -> String {
        var s = source
        while let call = s.range(of: "texSample2DLod(") {
            var depth = 1, i = call.upperBound, start = call.upperBound
            var args: [Substring] = []
            var close: String.Index?
            while i < s.endIndex {
                switch s[i] {
                case "(": depth += 1
                case ")": depth -= 1; if depth == 0 { args.append(s[start..<i]); close = i }
                case "," where depth == 1: args.append(s[start..<i]); start = s.index(after: i)
                default: break
                }
                if close != nil { break }
                i = s.index(after: i)
            }
            guard let closeIndex = close, args.count == 3 else { break }   // malformed — leave it
            let a = args.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            s.replaceSubrange(call.lowerBound...closeIndex, with: "\(a[0]).sample(\(a[0])_smp, \(a[1]), level(\(a[2])))")
        }
        return s
    }

    /// Rewrite WE/HLSL `mul(a, b)` matrix products to Metal's `(a) * (b)`, matching balanced parens so
    /// nested calls and comma-bearing arguments survive.
    private static func rewriteMul(_ source: String) -> String {
        var s = source
        var searchFrom = s.startIndex
        while let call = s.range(of: "mul(", range: searchFrom ..< s.endIndex) {
            // Skip a "mul(" that's the tail of a longer identifier (premul(, accumul(, …).
            if call.lowerBound > s.startIndex {
                let before = s[s.index(before: call.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { searchFrom = call.upperBound; continue }
            }
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
            searchFrom = s.startIndex   // the string shifted; rescan (skipping any leading premul again)
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

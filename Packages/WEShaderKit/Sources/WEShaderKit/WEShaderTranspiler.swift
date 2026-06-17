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
    /// `functionName`. Reuses `ShaderUniforms` to bind textures and a uniform buffer. When `pairedVertex`
    /// is given (the effect's own vertex), the stage_in struct mirrors THAT shader's varyings, so the two
    /// stages agree on every `[[user(locN)]]` slot and the pipeline links — the fragment body just reads
    /// whichever subset it uses. Standalone, it derives the struct from its own varyings, dropping any it
    /// never reads (a dead varying would otherwise shift the locations).
    public static func fragmentToMSL(_ source: String, functionName: String = "we_fragment",
                                     combos: [String: Int] = [:],
                                     includes: [String: String] = WEStandardHeaders.all,
                                     pairedVertex: String? = nil) -> String {
        let combos = ShaderPreprocessor.comboDefaults(source).merging(combos) { _, explicit in explicit }
        let resolved = ShaderPreprocessor.resolve(source, combos: combos, includes: includes)
        let uniforms = ShaderUniforms.parse(resolved)
        let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
        let scalars = uniforms.filter { !$0.type.hasPrefix("sampler") }
        // The stage_in varyings (which fix the [[user(locN)]] layout). With a paired vertex, use ITS
        // varyings verbatim — the fragment's must line up slot-for-slot with what the vertex writes, even
        // ones the fragment ignores. Standalone, use the fragment's own, dropping any it never reads (a
        // dead varying, e.g. waterripple's v_Scroll, would otherwise take a slot and shift the rest).
        let varyings: [(type: String, name: String, count: Int?)]
        if let pairedVertex {
            let vertexResolved = ShaderPreprocessor.resolve(pairedVertex, combos: combos, includes: includes)
            varyings = parseDeclarations(vertexResolved, keyword: "varying")
        } else {
            varyings = parseDeclarations(resolved, keyword: "varying").filter { isReferenced($0.name, in: resolved) }
        }

        // Qualify references: scalar varyings come from stage_in, scalar uniforms from the uniform
        // buffer, gl_FragColor → the local we return. Array varyings stay bare — they resolve to a local
        // array rebuilt below. The same map qualifies the global-touching helpers emitted as lambdas.
        let shadowed = locallyDeclaredNames(in: mainBody(of: resolved))
        var qualifiers: [(String, String)] = []
        for varying in varyings where varying.count == nil && !shadowed.contains(varying.name) {
            qualifiers.append((varying.name, "in.\(varying.name)"))
        }
        for uniform in scalars { qualifiers.append((uniform.name, "u.\(uniform.name)")) }
        qualifiers.append(("gl_FragColor", "_fragColor"))

        var body = rewriteTypes(rewriteIntrinsics(mainBody(of: resolved)))
        body = coerceVectorTruncations(body, vectorDims(of: resolved))
        for (name, replacement) in qualifiers { body = qualify(body, name: name, with: replacement) }

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + comboConstants(combos)
            + WEShaderPrelude.msl(omitting: preludeShadowedNames(of: resolved))
            + globalConstants(of: resolved) + helperFunctions(of: resolved)

        msl += "struct VaryingIn {\n" + varyingMembers(varyings) + "};\n\n"

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
        msl += arrayVaryingLocals(varyings, from: "in")
        msl += globalConstLocals(of: resolved, applying: qualifiers)
        msl += globalHelperLambdas(of: resolved, applying: qualifiers)
        msl += body
        msl += "\n    return _fragColor;\n}\n"
        return msl
    }

    /// Transpile a WE-dialect vertex shader to MSL with a vertex function named `functionName`.
    /// Attributes become a stage_in struct, varyings the output struct (carrying `[[position]]`), and
    /// `gl_Position` the output position.
    public static func vertexToMSL(_ source: String, functionName: String = "we_vertex",
                                   combos: [String: Int] = [:],
                                   includes: [String: String] = WEStandardHeaders.all) -> String {
        let combos = ShaderPreprocessor.comboDefaults(source).merging(combos) { _, explicit in explicit }
        let resolved = ShaderPreprocessor.resolve(source, combos: combos, includes: includes)
        let uniforms = ShaderUniforms.parse(resolved)
        let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
        let scalars = uniforms.filter { !$0.type.hasPrefix("sampler") }
        let attributes = parseDeclarations(resolved, keyword: "attribute")
        let varyings = parseDeclarations(resolved, keyword: "varying")

        // Attributes come from stage_in, scalar varyings/gl_Position go to the output struct, scalar
        // uniforms from the buffer. Array varyings stay bare (the body writes a local copied out below).
        // The same map qualifies the global-touching helpers emitted as lambdas.
        let shadowed = locallyDeclaredNames(in: mainBody(of: resolved))
        var qualifiers: [(String, String)] = []
        for attribute in attributes where !shadowed.contains(attribute.name) {
            qualifiers.append((attribute.name, "in.\(attribute.name)"))
        }
        for varying in varyings where varying.count == nil && !shadowed.contains(varying.name) {
            qualifiers.append((varying.name, "out.\(varying.name)"))
        }
        for uniform in scalars { qualifiers.append((uniform.name, "u.\(uniform.name)")) }
        qualifiers.append(("gl_Position", "out.position"))

        var body = rewriteTypes(rewriteIntrinsics(mainBody(of: resolved)))
        body = coerceVectorTruncations(body, vectorDims(of: resolved))
        for (name, replacement) in qualifiers { body = qualify(body, name: name, with: replacement) }

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n" + comboConstants(combos)
            + WEShaderPrelude.msl(omitting: preludeShadowedNames(of: resolved))
            + globalConstants(of: resolved) + helperFunctions(of: resolved)
        msl += "struct VertexIn {\n"
        for (index, attribute) in attributes.enumerated() {
            msl += "    \(mslType(attribute.type)) \(attribute.name) [[attribute(\(index))]];\n"
        }
        msl += "};\n\nstruct VertexOut {\n    float4 position [[position]];\n" + varyingMembers(varyings) + "};\n\n"
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
        msl += arrayVaryingDeclarations(varyings)
        msl += globalConstLocals(of: resolved, applying: qualifiers)
        msl += globalHelperLambdas(of: resolved, applying: qualifiers)
        msl += body
        msl += arrayVaryingWriteback(varyings)
        msl += "\n    return out;\n}\n"
        return msl
    }

    /// The vertex shader's `attribute` declarations, in declaration order — the order the transpiled MSL
    /// assigns their `[[attribute(i)]]` indices, so a caller can build a matching vertex descriptor.
    public static func vertexAttributes(_ source: String, combos: [String: Int] = [:],
                                        includes: [String: String] = WEStandardHeaders.all) -> [(type: String, name: String)] {
        let combos = ShaderPreprocessor.comboDefaults(source).merging(combos) { _, explicit in explicit }
        let resolved = ShaderPreprocessor.resolve(source, combos: combos, includes: includes)
        return parseDeclarations(resolved, keyword: "attribute").map { ($0.type, $0.name) }
    }

    /// Whether `name` appears in `source` beyond a single declaration — i.e. it is actually used. A whole
    /// word (not a substring or a `.member`); a declared-but-unused varying occurs exactly once (its
    /// declaration) so this returns false for it.
    private static func isReferenced(_ name: String, in source: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let regex = try! NSRegularExpression(pattern: "(?<![\\w.])\(escaped)(?![\\w])")
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) > 1
    }

    /// Names the body declares as locals via `<type> name [= …]`. GLSL lets a local shadow a varying or
    /// attribute of the same name (e.g. chromatic_aberration recomputes `vec4 bValue` over the interpolated
    /// `bValue`); the local owns the name inside the function, so we must NOT qualify it to `in.`/`out.` —
    /// doing so emits the invalid declaration `float4 in.bValue = …`. The local stays bare and the varying
    /// remains a (now unused) stage_in slot, preserving the layout.
    private static func locallyDeclaredNames(in body: String) -> Set<String> {
        let types = "(?:float|half|int|uint|bool|vec[234]|ivec[234]|uvec[234]|bvec[234]|mat[234]" +
                    "|mat[234]x[234]|float[234]|half[234]|float[234]x[234])"
        guard let re = try? NSRegularExpression(pattern: "\\b\(types)\\s+([A-Za-z_]\\w*)\\s*(?:=|;|\\[)") else { return [] }
        let ns = body as NSString
        var names = Set<String>()
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        return names
    }

    // MARK: - Pieces

    /// Emit the selected combo values as `#define`s so code that uses a combo as a runtime value (e.g.
    /// `ApplyBlending(BLENDMODE, …)`) sees its integer — matching how WE compiles combos into the shader.
    private static func comboConstants(_ combos: [String: Int]) -> String {
        guard !combos.isEmpty else { return "" }
        return combos.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)\n" }.joined() + "\n"
    }

    /// `<keyword> <type> <name>;` declarations (e.g. `varying`/`attribute`), de-duplicated by name. A
    /// `<name>[N]` array suffix (the blur/godray family declares `varying vec2 v_TexCoord[4]`) is captured
    /// as `count`; a non-literal size like `[RESOLUTION]` doesn't match and the declaration is skipped.
    private static func parseDeclarations(_ source: String, keyword: String) -> [(type: String, name: String, count: Int?)] {
        var result: [(type: String, name: String, count: Int?)] = []
        var seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"^\s*\#(keyword)\s+(\w+)\s+(\w+)\s*(?:\[\s*(\d+)\s*\])?\s*;"#)
        source.enumerateLines { line, _ in
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: whole),
                  let t = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) else { return }
            let name = String(line[n])
            // Clamp the array length: a shader is untrusted third-party input, and an absurd `[N]` would
            // otherwise expand to N members in a 0..<N loop (OOM/hang). Metal's interpolant budget is far
            // below this; an over-long array is treated as non-array, degrading to a no-op shader.
            let count = Range(m.range(at: 3), in: line).flatMap { Int(line[$0]) }.flatMap { (1...64).contains($0) ? $0 : nil }
            if seen.insert(name).inserted { result.append((type: String(line[t]), name: name, count: count)) }   // dedup repeats
        }
        return result
    }

    /// Component count of a GLSL type (1 for scalars), or nil for mat/sampler/unknown.
    private static func componentCount(of type: String) -> Int? {
        switch type {
        case "vec2", "float2", "ivec2", "uvec2", "bvec2": return 2
        case "vec3", "float3", "ivec3", "uvec3", "bvec3": return 3
        case "vec4", "float4", "ivec4", "uvec4", "bvec4": return 4
        case "float", "int", "uint", "bool", "half": return 1
        default: return nil
        }
    }

    /// Map every confidently-typed name in the shader to its component count: declared uniforms, varyings,
    /// attributes, the gl_* builtins, and local `vecN name`/`float name` declarations in the body.
    private static func vectorDims(of resolved: String) -> [String: Int] {
        var dims: [String: Int] = ["gl_FragCoord": 4, "gl_Position": 4, "gl_PointCoord": 2]
        for u in ShaderUniforms.parse(resolved) { if let c = componentCount(of: u.type) { dims[u.name] = c } }
        for keyword in ["varying", "attribute"] {
            for d in parseDeclarations(resolved, keyword: keyword) where d.count == nil {
                if let c = componentCount(of: d.type) { dims[d.name] = c }
            }
        }
        let local = try! NSRegularExpression(pattern: #"\b(vec[234]|float[234]?|ivec[234]|bvec[234])\s+([A-Za-z_]\w*)"#)
        let ns = resolved as NSString
        for m in local.matches(in: resolved, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 2))
            if dims[name] == nil, let c = componentCount(of: ns.substring(with: m.range(at: 1))) { dims[name] = c }
        }
        return dims
    }

    /// Component count of a SIMPLE operand — a literal, a typed name (optionally swizzled), or a vecN/float
    /// constructor. nil for anything compound (a binary expression, an unknown call) so the caller leaves it
    /// untouched. Used to spot — and only spot — dimension mismatches that are safe to truncate.
    private static func operandDim(_ token: String, _ dims: [String: Int]) -> Int? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[-+]?[0-9.]+$"#, options: .regularExpression) != nil { return 1 }   // numeric literal
        if let m = t.range(of: #"^(vec([234])|float([234])?)\s*\("#, options: .regularExpression) {
            let head = t[t.startIndex..<m.upperBound]
            if head.contains("4") { return 4 }; if head.contains("3") { return 3 }; if head.contains("2") { return 2 }
            return 1   // float(...)
        }
        guard t.range(of: #"^[A-Za-z_]\w*(\.[xyzwrgba]+)?$"#, options: .regularExpression) != nil else { return nil }
        if let dot = t.firstIndex(of: ".") { return t.distance(from: t.index(after: dot), to: t.endIndex) }   // swizzle
        return dims[t]
    }

    /// Append the leading-N swizzle (.x/.xy/.xyz) that truncates a vector to `target` components.
    private static func truncated(_ token: String, to target: Int) -> String {
        token + "." + String("xyzw".prefix(target))
    }

    /// Component-wise intrinsics whose vector arguments must all share one dimension (the scalar `t`/edges
    /// broadcast). WE's HLSL-derived shaders pass a wider vector and rely on implicit truncation — e.g.
    /// `mix(albedo /*vec4*/, newAlbedo /*vec3*/, mask)` — which MSL rejects.
    private static let componentwiseFns: Set<String> = ["mix", "clamp", "min", "max", "step", "smoothstep", "pow", "mod", "fmod"]

    /// Split a comma list at top level, respecting nested ()/[] (so `vec3(a,b,c)` stays one argument).
    private static func splitTopLevelArgs(_ s: String) -> [String] {
        var args: [String] = []; var depth = 0; var cur = ""
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1; cur.append(ch) }
            else if ch == ")" || ch == "]" { depth -= 1; cur.append(ch) }
            else if ch == "," && depth == 0 { args.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        if !cur.isEmpty || !args.isEmpty { args.append(cur) }
        return args
    }

    /// Harmonise the vector arguments of component-wise intrinsic calls in `line`: when every argument is a
    /// simple, confidently-typed operand and the vector ones disagree in width, truncate the wider to the
    /// narrowest vector width (scalars broadcast and are left alone). Regression-safe: a call that already
    /// type-checks has equal vector widths, so the minimum equals them all and nothing is rewritten; only a
    /// genuinely mismatched (non-compiling) call is touched. Skips any call with a compound argument so a
    /// width it can't see never drives a wrong truncation. Recurses into nested calls.
    private static func harmonizeComponentwiseArgs(_ line: String, _ dims: [String: Int]) -> String {
        let chars = Array(line); let n = chars.count
        var result = ""; var i = 0
        while i < n {
            let ch = chars[i]
            if ch.isLetter || ch == "_" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[i..<j])
                let isMember = i > 0 && chars[i - 1] == "."
                if !isMember, componentwiseFns.contains(name), j < n, chars[j] == "(" {
                    var depth = 0, k = j
                    while k < n { if chars[k] == "(" { depth += 1 } else if chars[k] == ")" { depth -= 1; if depth == 0 { break } }; k += 1 }
                    if k < n {
                        let inner = String(chars[(j + 1)..<k])
                        result += name + "(" + harmonizeArgList(inner, dims) + ")"
                        i = k + 1; continue
                    }
                }
                result += name; i = j; continue
            }
            result.append(ch); i += 1
        }
        return result
    }

    private static func harmonizeArgList(_ inner: String, _ dims: [String: Int]) -> String {
        let args = splitTopLevelArgs(inner).map { harmonizeComponentwiseArgs($0, dims) }
        guard args.count >= 2 else { return args.joined(separator: ",") }
        let argDims = args.map { operandDim($0.trimmingCharacters(in: .whitespaces), dims) }
        guard !argDims.contains(where: { $0 == nil }) else { return args.joined(separator: ",") }
        let vectorWidths = argDims.compactMap { $0 }.filter { $0 > 1 }
        guard let minVec = vectorWidths.min(), vectorWidths.count >= 2, vectorWidths.contains(where: { $0 > minVec }) else {
            return args.joined(separator: ",")
        }
        let out = zip(args, argDims).map { arg, d -> String in
            guard let d, d > minVec, d > 1 else { return arg }
            let lead = String(arg.prefix(while: { $0 == " " }))
            return lead + truncated(arg.trimmingCharacters(in: .whitespaces), to: minVec)
        }
        return out.joined(separator: ",")
    }

    /// WE's shaders are HLSL-derived and rely on implicit vector truncation (assigning/passing a vecM where a
    /// vecN, N<M, is wanted); MSL rejects it. Insert the leading-N swizzle for the cases we can type with full
    /// confidence — a simple operand assigned to a smaller declared target, and a vec4/vec3 passed where a
    /// known builtin wants vec2. Anything compound (a binary expression) is left untouched, so a shader that
    /// already type-checks is never rewritten.
    private static func coerceVectorTruncations(_ body: String, _ dims: [String: Int]) -> String {
        // Functions whose first parameter is a 2-component vector (a vecM arg is truncated to .xy).
        let vec2FirstParam: Set<String> = ["rotateVec2"]
        var out: [String] = []
        for rawLine in body.components(separatedBy: "\n") {
            var line = rawLine
            // (0) Harmonise component-wise intrinsic args (mix/clamp/…) whose vector widths disagree.
            line = harmonizeComponentwiseArgs(line, dims)
            // (1) `[type] lhs = rhs;` where rhs is a single operand wider than the target.
            let ns0 = line as NSString
            let assign = try! NSRegularExpression(pattern: #"^(\s*)(?:(vec[234]|float[234]?)\s+)?([A-Za-z_]\w*(?:\.[xyzwrgba]+)?)\s*=\s*([^=;][^;]*);\s*$"#)
            if let r = assign.firstMatch(in: line, range: NSRange(location: 0, length: ns0.length)) {
                let indent = ns0.substring(with: r.range(at: 1))
                let declType = r.range(at: 2).location != NSNotFound ? ns0.substring(with: r.range(at: 2)) : ""
                let lhs = ns0.substring(with: r.range(at: 3))
                let rhs = ns0.substring(with: r.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let lhsDim = !declType.isEmpty ? componentCount(of: declType) : operandDim(lhs, dims)
                if let lhsDim, lhsDim >= 1, lhsDim <= 3, let rhsDim = operandDim(rhs, dims), rhsDim > lhsDim {
                    let lhsPart = declType.isEmpty ? lhs : "\(declType) \(lhs)"
                    line = "\(indent)\(lhsPart) = \(truncated(rhs, to: lhsDim));"
                }
            }
            // (2) `fn(arg, …)` for a known vec2-first-param function, arg a wider simple operand.
            for fn in vec2FirstParam {
                let re = try! NSRegularExpression(pattern: "\\b\(fn)\\(\\s*([A-Za-z_]\\w*(?:\\.[xyzwrgba]+)?)\\s*,")
                let ns = line as NSString
                if let r = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let arg = ns.substring(with: r.range(at: 1))
                    if let d = operandDim(arg, dims), d > 2 {
                        line = line.replacingOccurrences(of: "\(fn)(\(arg),", with: "\(fn)(\(truncated(arg, to: 2)),")
                    }
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// The `[[user(locn…)]]` member declarations for `varyings`. MSL forbids an array member in a
    /// `[[stage_in]]` or vertex-out struct, so an array varying `T name[N]` is expanded into N
    /// consecutively-located scalar members `name_0 … name_{N-1}` that the body packs into / unpacks from
    /// a local array. A running counter (not the declaration index) assigns locations so an array's N
    /// members don't collide with later varyings.
    private static func varyingMembers(_ varyings: [(type: String, name: String, count: Int?)]) -> String {
        var out = ""
        var location = 0
        for varying in varyings {
            if let count = varying.count {
                for k in 0..<count { out += "    \(mslType(varying.type)) \(varying.name)_\(k) [[user(locn\(location))]];\n"; location += 1 }
            } else {
                out += "    \(mslType(varying.type)) \(varying.name) [[user(locn\(location))]];\n"; location += 1
            }
        }
        return out
    }

    /// For each array varying, a local `T name[N] = { in.name_0, … };` rebuilt from the expanded stage_in
    /// members, so the fragment body can index it — including with a dynamic loop variable, which a struct
    /// member can't be. Scalar varyings are read straight through `in.name`.
    private static func arrayVaryingLocals(_ varyings: [(type: String, name: String, count: Int?)], from container: String) -> String {
        var out = ""
        for varying in varyings {
            guard let count = varying.count else { continue }
            let elements = (0..<count).map { "\(container).\(varying.name)_\($0)" }.joined(separator: ", ")
            out += "    \(mslType(varying.type)) \(varying.name)[\(count)] = { \(elements) };\n"
        }
        return out
    }

    /// The local array declarations a vertex body writes into before they're copied to the output struct.
    private static func arrayVaryingDeclarations(_ varyings: [(type: String, name: String, count: Int?)]) -> String {
        varyings.compactMap { varying in varying.count.map { "    \(mslType(varying.type)) \(varying.name)[\($0)];\n" } }.joined()
    }

    /// Copy each local array varying back into the output struct's expanded members before `return out`.
    private static func arrayVaryingWriteback(_ varyings: [(type: String, name: String, count: Int?)]) -> String {
        var out = ""
        for varying in varyings {
            guard let count = varying.count else { continue }
            for k in 0..<count { out += "    out.\(varying.name)_\(k) = \(varying.name)[\(k)];\n" }
        }
        return out
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
    /// calls them compiles. A helper that touches the fragment's globals (g_*/u_* uniforms, samplers,
    /// gl_*) — directly or by calling one that does — is skipped here: a free MSL function can't reach them,
    /// so `globalHelperLambdas` emits it as a lambda inside main instead. A helper whose name the prelude
    /// also defines IS emitted (the shader's version is authoritative; `preludeShadowedNames` drops the
    /// prelude's copy so there's no redefinition).
    private static func helperFunctions(of source: String) -> String {
        let cleaned = stripDirectivesAndComments(source)
        let hosted = globalsTouchingFunctions(of: source)
        var out = ""
        for (signature, body) in topLevelBlocks(cleaned) {
            guard signature.contains("(") else {   // a struct or non-function block
                if signature.trimmingCharacters(in: .whitespaces).hasPrefix("struct") {
                    out += rewriteTypes(signature) + " {" + rewriteTypes(body) + "};\n"
                }
                continue
            }
            let name = functionName(of: signature)
            if name.isEmpty || name == "main" || hosted.contains(name) { continue }
            out += rewriteParamQualifiers(rewriteTypes(rewriteIntrinsics(signature))) + " {" + rewriteTypes(rewriteIntrinsics(body)) + "}\n"
        }
        return out
    }

    /// In-file helpers that touch the fragment's globals, emitted as `[&]`-capturing lambdas at the top of
    /// main where the textures/samplers/uniform buffer and stage-in/out are in scope (an MSL lambda can
    /// capture all of them and call an earlier lambda). Bodies are rewritten and qualified exactly like
    /// main's, so a uniform reads `u.x`, a varying `in.x`/`out.x`, etc. Source order is preserved so a
    /// helper that calls another is defined after it.
    private static func globalHelperLambdas(of source: String, applying qualifiers: [(String, String)]) -> String {
        let cleaned = stripDirectivesAndComments(source)
        let hosted = globalsTouchingFunctions(of: source)
        var out = ""
        for (signature, body) in topLevelBlocks(cleaned) where signature.contains("(") {
            let name = functionName(of: signature)
            guard hosted.contains(name), let paren = signature.firstIndex(of: "("),
                  let close = signature.range(of: ")", options: .backwards) else { continue }
            let head = signature[..<paren].trimmingCharacters(in: .whitespaces)   // "<return type> <name>"
            guard let nameRange = head.range(of: name, options: .backwards) else { continue }
            let returnType = head[..<nameRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let params = rewriteParamQualifiers(rewriteTypes(rewriteIntrinsics(String(signature[signature.index(after: paren)..<close.lowerBound]))))
            var lambdaBody = rewriteTypes(rewriteIntrinsics(body))
            for (n, r) in qualifiers { lambdaBody = qualify(lambdaBody, name: n, with: r) }
            out += "    auto \(name) = [&] (\(params)) -> \(returnType.isEmpty ? "auto" : rewriteTypes(returnType)) {\(lambdaBody)};\n"
        }
        return out
    }

    /// The names of in-file functions that reference the fragment's globals, transitively: directly using
    /// a g_*/u_* name, a sampler or gl_*, or calling a function that does. These can't be free MSL
    /// functions; `globalHelperLambdas` hosts them inside main instead.
    private static func globalsTouchingFunctions(of source: String) -> Set<String> {
        let cleaned = stripDirectivesAndComments(source)
        let uniformConsts = uniformDerivedConstNames(of: source)
        // Every parsed scalar uniform, by name — not every WE uniform uses the g_/u_ prefix (tone mapping's
        // are t_*, a_*), so a prefix test misses them; match the real declared names instead.
        let uniformNames = ShaderUniforms.parse(source).filter { !$0.type.hasPrefix("sampler") }.map(\.name)
        var functions: [(name: String, text: String)] = []
        for (signature, body) in topLevelBlocks(cleaned) where signature.contains("(") {
            let name = functionName(of: signature)
            if !name.isEmpty, name != "main" { functions.append((name, signature + body)) }
        }
        func referencesAny(_ text: String, _ names: [String]) -> Bool {
            names.contains { name in
                text.range(of: "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: name))(?![\\w])", options: .regularExpression) != nil
            }
        }
        // A helper "touches globals" if it reads a g_*/u_*/sampler/gl_* directly, a uniform of any prefix,
        // OR a file-scope const that is itself uniform-derived (and so lives as a main-local).
        func touchesGlobals(_ text: String) -> Bool {
            referencesGlobals(text) || referencesAny(text, uniformNames) || referencesAny(text, Array(uniformConsts))
        }
        var touching = Set(functions.filter { touchesGlobals($0.text) }.map(\.name))
        var changed = true
        while changed {
            changed = false
            for f in functions where !touching.contains(f.name) {
                if touching.contains(where: { callee in
                    f.text.range(of: "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: callee))\\s*\\(", options: .regularExpression) != nil
                }) { touching.insert(f.name); changed = true }
            }
        }
        return touching
    }

    /// Whether `text` references one of the fragment's globals — a g_*/u_* uniform, a sampler (via
    /// texSample) or a gl_* builtin. These aren't reachable from a free MSL function or a file-scope
    /// `constant`, so anything referencing one is hosted inside main instead.
    private static func referencesGlobals(_ text: String) -> Bool {
        text.contains("g_") || text.contains("u_") || text.contains("texSample") || text.contains("gl_")
    }

    /// The declared name in a `const <type> <name>[…] = …` statement — the leading identifier of the
    /// second token, dropping any `[N]` array suffix (so `const float arr[2] = …` yields `arr`, not
    /// `arr[2]`). "" if it can't be parsed.
    private static func constName(of trimmed: String) -> String {
        let tokens = trimmed.dropFirst("const ".count).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        guard let nameToken = tokens.dropFirst().first else { return "" }
        return String(nameToken.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
    }

    /// Names of file-scope `const`s that are uniform-derived (e.g. a transition shader's
    /// `const float FEATHER = u_Feather * 0.5;`). MSL's `constant` address space needs a compile-time
    /// constant and can't see the uniform buffer, so these are emitted as qualified main-locals by
    /// `globalConstLocals` rather than at file scope. The set is closed transitively: a const whose
    /// initializer reads a uniform/global is derived, and so is one that references an already-derived
    /// const (`const AB = A * 3.0;` where `A` is itself a main-local) — emitting that at file scope would
    /// reference a name that only exists inside main.
    private static func uniformDerivedConstNames(of source: String) -> Set<String> {
        let cleaned = stripDirectivesAndComments(source)
        var consts: [(name: String, text: String)] = []
        for statement in topLevelStatements(cleaned) {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("const ") else { continue }
            let name = constName(of: trimmed)
            if !name.isEmpty { consts.append((name, trimmed)) }
        }
        var derived = Set<String>()
        var changed = true
        while changed {
            changed = false
            for c in consts where !derived.contains(c.name) {
                let refsDerived = derived.contains { d in
                    c.text.range(of: "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: d))(?![\\w])", options: .regularExpression) != nil
                }
                if referencesGlobals(c.text) || refsDerived { derived.insert(c.name); changed = true }
            }
        }
        return derived
    }

    /// The shader source with `#` directives and comments stripped — the form the block/helper scanners
    /// walk.
    private static func stripDirectivesAndComments(_ source: String) -> String {
        stripLineComments(stripBlockComments(source)).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
    }

    /// The names of prelude functions the shader redefines in-file as plain (non-global-touching) helpers.
    /// The prelude omits these so the shader's own copy wins instead of being silently shadowed.
    private static func preludeShadowedNames(of source: String) -> Set<String> {
        let cleaned = stripDirectivesAndComments(source)
        let hosted = globalsTouchingFunctions(of: source)
        var names: Set<String> = []
        for (signature, _) in topLevelBlocks(cleaned) where signature.contains("(") {
            let name = functionName(of: signature)
            if !name.isEmpty, name != "main", !hosted.contains(name), preludeFunctionNames.contains(name) {
                names.insert(name)
            }
        }
        return names
    }

    /// Emit the shader's file-scope `const` declarations (e.g. WE's ACES tone-map matrices
    /// `const mat3 aces_input_matrix = mat3(…)`) in MSL's `constant` address space, so the helper
    /// functions and main that reference them resolve. Only `const`-qualified top-level statements are
    /// taken — uniforms, varyings and attributes are bound elsewhere — and they're emitted before the
    /// helpers, which may read them. A const whose initializer reads a uniform/global is skipped here and
    /// hoisted into main by `globalConstLocals` (the `constant` address space can't see the uniform buffer).
    private static func globalConstants(of source: String) -> String {
        let cleaned = stripLineComments(stripBlockComments(source)).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        let derived = uniformDerivedConstNames(of: source)
        var out = ""
        for statement in topLevelStatements(cleaned) {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("const "), !derived.contains(constName(of: trimmed)) else { continue }
            out += "constant " + rewriteTypes(rewriteIntrinsics(String(trimmed.dropFirst("const ".count)))) + ";\n"
        }
        return out
    }

    /// Hoist file-scope `const`s whose initializer reads a uniform/global into main as qualified locals, in
    /// declaration order, ahead of the helper lambdas that may capture them. The uniform reference is
    /// qualified (`u_Feather` → `u.u_Feather`) exactly like main's body, which a file-scope `constant`
    /// can't be.
    private static func globalConstLocals(of source: String, applying qualifiers: [(String, String)]) -> String {
        let cleaned = stripLineComments(stripBlockComments(source)).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        let derived = uniformDerivedConstNames(of: source)
        var out = ""
        for statement in topLevelStatements(cleaned) {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("const "), derived.contains(constName(of: trimmed)) else { continue }
            var decl = rewriteTypes(rewriteIntrinsics(String(trimmed.dropFirst("const ".count))))
            for (name, replacement) in qualifiers { decl = qualify(decl, name: name, with: replacement) }
            out += "    \(decl);\n"
        }
        return out
    }

    /// The top-level statements terminated by `;` at brace-depth 0 (declarations), skipping `{ … }`
    /// blocks (functions and structs, handled by `topLevelBlocks`/`mainBody`).
    private static func topLevelStatements(_ source: String) -> [String] {
        var statements: [String] = []
        var depth = 0
        var start = source.startIndex
        var i = source.startIndex
        while i < source.endIndex {
            switch source[i] {
            case "{": depth += 1
            case "}": depth -= 1; if depth == 0 { start = source.index(after: i) }   // end of a block
            case ";" where depth == 0:
                statements.append(String(source[start..<i]))
                start = source.index(after: i)
            default: break
            }
            i = source.index(after: i)
        }
        return statements
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
        out = rewriteArrayConstructors(out)   // GLSL T[N](a, b, …) → MSL brace-init {a, b, …}
        out = promoteNumericLiterals(out)   // min(x, 1) with a float x → min(x, 1.0)
        out = rewriteReservedWords(out)
        // (mod and two-arg atan are defined in the prelude — GLSL semantics differ from Metal's.)
        for (glsl, msl) in [("frac", "fract"), ("inversesqrt", "rsqrt"), ("lerp", "mix")] {
            out = replaceWord(out, glsl, msl)
        }
        return out
    }

    /// Promote a bare integer-literal argument of `min`/`max`/`clamp` to a float when a sibling argument is
    /// a presumed-float value. WE/HLSL treat these as float, but MSL has no `min(int, float)` overload, so
    /// `min(x, 1)` with a float `x` is "call ambiguous". A call whose arguments are ALL integer literals
    /// (`min(2, 3)`) — or where any argument is an `int`/`uint`-declared identifier (`clamp(i, 0, n-1)`) —
    /// is left untouched, so genuine integer arithmetic keeps its type. Nested same-named calls are reached
    /// because the search resumes inside the call, not past it.
    private static func promoteNumericLiterals(_ source: String) -> String {
        let intLiteral = try! NSRegularExpression(pattern: #"^-?\d+$"#)
        func isIntLiteral(_ s: Substring) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return intLiteral.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
        // Identifiers declared `int`/`uint` (including a `for (int i …)` counter) — a literal beside one of
        // these is integer arithmetic, not a float call, so it must not be promoted.
        var intIdentifiers = Set<String>()
        let intDecl = try! NSRegularExpression(pattern: #"\b(?:int|uint)\s+(\w+)"#)
        for match in intDecl.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let r = Range(match.range(at: 1), in: source) { intIdentifiers.insert(String(source[r])) }
        }
        func isKnownInt(_ s: Substring) -> Bool { intIdentifiers.contains(s.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var s = source
        for fn in ["min", "max", "clamp"] {
            var searchFrom = s.startIndex
            while let call = s.range(of: fn + "(", range: searchFrom ..< s.endIndex) {
                if call.lowerBound > s.startIndex {
                    let before = s[s.index(before: call.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" || before == "." { searchFrom = call.upperBound; continue }
                }
                // Collect top-level argument ranges.
                var depth = 0, i = s.index(before: call.upperBound), argStart = call.upperBound
                var args: [Range<String.Index>] = []
                var close: String.Index?
                while i < s.endIndex {
                    switch s[i] {
                    case "(": depth += 1
                    case ")": depth -= 1; if depth == 0 { args.append(argStart..<i); close = i }
                    case "," where depth == 1: args.append(argStart..<i); argStart = s.index(after: i)
                    default: break
                    }
                    if close != nil { break }
                    i = s.index(after: i)
                }
                guard let closeIndex = close else { break }
                let mixed = args.contains { isIntLiteral(s[$0]) } && args.contains { !isIntLiteral(s[$0]) }
                    && !args.contains { isKnownInt(s[$0]) }
                if mixed {
                    // Rebuild the call, promoting each integer-literal argument to a float literal.
                    var rebuilt = ""
                    for (index, arg) in args.enumerated() {
                        let text = s[arg]
                        rebuilt += index == 0 ? "" : ","
                        rebuilt += isIntLiteral(text) ? text.trimmingCharacters(in: .whitespacesAndNewlines) + ".0" : String(text)
                    }
                    // Resume just inside this call (like the non-mixed branch) so a nested same-named call is
                    // still reached, but WITHOUT re-scanning from the start: a from-start rescan after every
                    // promotion is O(N²) and a crafted shader with thousands of calls would stall the build.
                    // The mutation only touches text after `call.upperBound`, so its offset from the start is
                    // stable; recover the index from it once the replace has invalidated the old one.
                    let resumeOffset = s.distance(from: s.startIndex, to: call.upperBound)
                    s.replaceSubrange(call.upperBound...closeIndex, with: rebuilt + ")")
                    searchFrom = s.index(s.startIndex, offsetBy: resumeOffset)
                } else {
                    searchFrom = call.upperBound   // resume inside the call so a nested same-named call is reached
                }
            }
        }
        return s
    }

    /// Translate GLSL parameter direction qualifiers, which MSL has no spelling for, into MSL parameter
    /// forms. GLSL's `out`/`inout T x` — a written-back argument, used by auto_sway's `calNode`/`preCalcNode`
    /// and the lens shaders' `computeUV(in vec2 coord, …, out vec2 uv)` — becomes a `thread T&` reference: the
    /// caller already passes an lvalue, which binds to the reference and receives the write, so call sites
    /// need no change. GLSL's explicit `in T x` is MSL's default, so the qualifier is dropped. Runs after the
    /// type/intrinsic rewrites, so it sees MSL type names and the `thread` keyword it introduces isn't itself
    /// renamed by `rewriteReservedWords`.
    private static func rewriteParamQualifiers(_ params: String) -> String {
        let mslType = #"(?:void|bool|uint|int[234]?|float[234]?(?:x[234])?)"#
        var out = params
        out = out.replacingOccurrences(of: #"\b(?:out|inout)\s+(\#(mslType))\b"#,
                                       with: "thread $1&", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\bin\s+(\#(mslType))\b"#,
                                       with: "$1", options: .regularExpression)
        return out
    }

    /// Rename shader identifiers that collide with MSL reserved words — a variable called `kernel` (Metal's
    /// compute-function keyword) or `fragment` (a WE waterwaves shader names a coordinate that) makes Metal
    /// read the keyword and report "expected expression". This only runs over shader-derived code, never
    /// the wrapper we generate, so our own `fragment`/`constant` keywords are untouched.
    private static func rewriteReservedWords(_ source: String) -> String {
        var out = source
        for word in ["kernel", "fragment", "vertex", "device", "constant", "threadgroup", "thread"] {
            out = replaceWord(out, word, "we_id_\(word)")
        }
        return out
    }

    /// Rewrite a GLSL array constructor `Type[N]( a, b, … )` (e.g. a bokeh kernel `vec2[9](KERNEL22)`) to
    /// MSL's brace initializer `{ a, b, … }`. Only known scalar/vector/matrix type names lead a match, so
    /// an ordinary subscript like `arr[i]` followed by a call is never mistaken for a constructor.
    private static func rewriteArrayConstructors(_ source: String) -> String {
        var s = source
        let types = "vec2|vec3|vec4|mat2|mat3|mat4|ivec2|ivec3|ivec4|float2|float3|float4|float|int"
        let regex = try! NSRegularExpression(pattern: "\\b(?:\(types))\\s*\\[\\s*\\w+\\s*\\]\\s*\\(")
        // Search forward from the last rewrite rather than from the start each time: a from-start scan after
        // every replacement is O(N²) and a crafted shader with many constructors would stall the build.
        // Resuming at the replacement's `{` still lets a nested constructor inside it be found next pass.
        var searchStart = s.startIndex
        while let m = regex.firstMatch(in: s, range: NSRange(searchStart..<s.endIndex, in: s)),
              let head = Range(m.range, in: s) {
            let openParen = s.index(before: head.upperBound)   // the "(" the match ends on
            var depth = 0, i = openParen
            var close: String.Index?
            while i < s.endIndex {
                if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1; if depth == 0 { close = i; break } }
                i = s.index(after: i)
            }
            guard let closeIndex = close else { break }   // unbalanced — leave it
            let elements = s[s.index(after: openParen)..<closeIndex]
            let resumeOffset = s.distance(from: s.startIndex, to: head.lowerBound)
            s.replaceSubrange(head.lowerBound...closeIndex, with: "{\(elements)}")
            searchStart = s.index(s.startIndex, offsetBy: resumeOffset)
        }
        return s
    }

    /// `texSample2DLod(g_Tex, uv, lod)` → `g_Tex.sample(g_Tex_smp, uv, level(lod))`, matching balanced
    /// parens so nested calls in the uv/lod arguments survive.
    private static func rewriteTexLod(_ source: String) -> String {
        var s = source
        var searchFrom = s.startIndex   // resume past each rewrite; rescanning from the start is O(N²)
        while let call = s.range(of: "texSample2DLod(", range: searchFrom ..< s.endIndex) {
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
            let resumeOffset = s.distance(from: s.startIndex, to: call.lowerBound)
            s.replaceSubrange(call.lowerBound...closeIndex, with: "\(a[0]).sample(\(a[0])_smp, \(a[1]), level(\(a[2])))")
            searchFrom = s.index(s.startIndex, offsetBy: resumeOffset)   // a nested call in the args is still reached
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
            let resumeOffset = s.distance(from: s.startIndex, to: call.lowerBound)
            s.replaceSubrange(call.lowerBound...closeIndex, with: "((\(a)) * (\(b)))")
            searchFrom = s.index(s.startIndex, offsetBy: resumeOffset)   // resume at the replacement; a nested mul inside it is still reached, without an O(N²) rescan
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
                            // CAST3X3 truncates a mat4 to its upper-left 3×3; Metal has no such
                            // constructor, so route it through the prelude helper instead of float3x3(…).
                            ("CAST2X2", "float2x2"), ("CAST3X3", "_weCast3x3"), ("CAST4X4", "float4x4")] {
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

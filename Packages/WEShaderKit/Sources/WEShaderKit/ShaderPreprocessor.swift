// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Resolves a WE shader's `#if`/`#ifdef`/`#elif`/`#else`/`#endif` combo
// conditionals against the combo values an effect selects, keeping only the active branches so the
// transpiled shader takes the right code path. Other `#` directives pass through. No GPL.
import Foundation

public enum ShaderPreprocessor {
    /// Keep only the lines in branches that are active for `combos` (a missing combo reads as 0). Any
    /// `#include "name"` is first spliced with `includes[name]` — WE's effect shaders pull blend, blur
    /// and math helpers from standard headers that ship with the engine, not inside the wallpaper.
    public static func resolve(_ source: String, combos: [String: Int], includes: [String: String] = [:]) -> String {
        // WE shaders ship with Windows CRLF endings. Swift treats "\r\n" as a single grapheme, so
        // split(separator: "\n") would never match it and the whole file would collapse into one
        // "line" — normalise to LF up front so every line-based step downstream works.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Splice headers in before conditionals/macros so a header's own #define/#if participates.
        let source = includes.isEmpty ? normalized : expandIncludes(normalized, includes)
        struct Frame { let parentEmitting: Bool; var taken: Bool; var active: Bool }
        var stack: [Frame] = []
        func emitting() -> Bool { stack.last.map { $0.parentEmitting && $0.active } ?? true }

        // Macros collected as they appear and substituted into the lines that follow (C semantics: a
        // macro takes effect from its definition downward). Object-like `#define NAME value` ones also
        // seed the combo set when their value is an integer (so a later `#if NAME == …` sees it).
        // Function-like `#define NAME(args) body` ones are expanded at each call site — WE's blur headers
        // inject the framebuffer this way, e.g. `#define blur13a(uv, step) _blur13a(g_Texture0, …)`.
        var combos = combos
        var macros: [(name: String, value: String)] = []
        var funcMacros: [(name: String, params: [String], body: String)] = []
        // Every `#define` makes its name "defined" for `#ifdef`/`#ifndef`/`defined()`, regardless of whether
        // its value parses as an integer combo — a valueless `#define HQ`, a function-like `#define BLUR(x)…`,
        // and a non-integer `#define DEG2RAD 0.017` are all defined. `combos` alone (seeded only for integer
        // values) would miss them and select the wrong conditional branch.
        var definedNames: Set<String> = []

        var output: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#ifdef ") || trimmed.hasPrefix("#ifndef ") {
                let parent = emitting()
                let value = parent && evaluate(condition(trimmed), combos: combos, defined: definedNames)
                stack.append(Frame(parentEmitting: parent, taken: value, active: value))
            } else if trimmed.hasPrefix("#elif ") {
                guard var frame = stack.popLast() else { continue }
                frame.active = frame.parentEmitting && !frame.taken && evaluate(stripTrailingComment(String(trimmed.dropFirst(6))), combos: combos, defined: definedNames)
                frame.taken = frame.taken || frame.active
                stack.append(frame)
            } else if trimmed.hasPrefix("#else") {
                guard var frame = stack.popLast() else { continue }
                frame.active = frame.parentEmitting && !frame.taken
                frame.taken = true
                stack.append(frame)
            } else if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if emitting() {
                if let fn = funcMacro(trimmed) {
                    funcMacros.append(fn)
                    definedNames.insert(fn.name)
                } else if let (name, value) = objectMacro(trimmed) {
                    let expanded = expandMacros(value, macros, funcMacros)
                    macros.append((name: name, value: expanded))
                    definedNames.insert(name)
                    if let int = Int(expanded) { combos[name] = int }   // visible to a later #if NAME
                } else {
                    output.append(macros.isEmpty && funcMacros.isEmpty ? line : expandMacros(line, macros, funcMacros))
                }
            }
        }
        return output.joined(separator: "\n")
    }

    /// An object-like `#define NAME value` (NAME a bare identifier), as `(name, value)`. Returns nil for a
    /// function-like macro `#define NAME(args) …` (the `(` abuts the name) — those are rewritten by the
    /// transpiler — and for any non-`#define` line. A valueless `#define NAME` yields an empty value.
    private static func objectMacro(_ line: String) -> (String, String)? {
        guard line.hasPrefix("#define ") else { return nil }
        let rest = Substring(line.dropFirst("#define".count)).drop { $0 == " " || $0 == "\t" }
        var nameEnd = rest.startIndex
        while nameEnd < rest.endIndex, rest[nameEnd].isLetter || rest[nameEnd].isNumber || rest[nameEnd] == "_" {
            nameEnd = rest.index(after: nameEnd)
        }
        let name = String(rest[rest.startIndex..<nameEnd])
        guard !name.isEmpty else { return nil }
        if nameEnd < rest.endIndex, rest[nameEnd] == "(" { return nil }   // function-like — leave it
        return (name, stripTrailingComment(String(rest[nameEnd...])).trimmingCharacters(in: .whitespaces))
    }

    /// Truncate a macro value/body at a trailing `//` or `/*` comment. A `#define` is parsed before the
    /// line comment-stripper runs, so the comment text would otherwise be substituted into live code (and
    /// the later strip would then eat the following `;`/tokens). GLSL has no string literals, so the first
    /// `//`/`/*` is unambiguously a comment.
    private static func stripTrailingComment(_ text: String) -> String {
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if text[i] == "/", next < text.endIndex, text[next] == "/" || text[next] == "*" { return String(text[..<i]) }
            i = next
        }
        return text
    }

    /// A function-like `#define NAME(p1, p2) body` (the `(` abuts the name), as `(name, params, body)`;
    /// nil for an object-like or non-`#define` line.
    private static func funcMacro(_ line: String) -> (name: String, params: [String], body: String)? {
        guard line.hasPrefix("#define ") else { return nil }
        let rest = String(Substring(line.dropFirst("#define".count)).drop { $0 == " " || $0 == "\t" })
        var nameEnd = rest.startIndex
        while nameEnd < rest.endIndex, rest[nameEnd].isLetter || rest[nameEnd].isNumber || rest[nameEnd] == "_" {
            nameEnd = rest.index(after: nameEnd)
        }
        let name = String(rest[rest.startIndex..<nameEnd])
        guard !name.isEmpty, nameEnd < rest.endIndex, rest[nameEnd] == "(",
              let close = matchingParen(rest, nameEnd) else { return nil }
        let params = rest[rest.index(after: nameEnd)..<close]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = stripTrailingComment(String(rest[rest.index(after: close)...])).trimmingCharacters(in: .whitespaces)
        return (name, params, body)
    }

    /// Past this expanded size a macro expansion is treated as a crafted reduplication bomb and stopped.
    /// Checked at every level that can amplify text (the pass loop AND the inner replace loops), since a
    /// single pass of a doubling macro (`#define X X X`) can blow past it on its own.
    static let maxExpansionBytes = 1_000_000

    /// Expand macros in `text` to a fixed point: function-like calls first (so an injected name can itself
    /// be an object macro), then object-like substitution. Bounded so a self-referential macro can't loop.
    private static func expandMacros(_ text: String, _ macros: [(name: String, value: String)],
                                     _ funcMacros: [(name: String, params: [String], body: String)]) -> String {
        var out = text
        for _ in 0..<8 {
            var changed = false
            if !funcMacros.isEmpty {
                let expanded = expandFunctionMacros(out, funcMacros)
                if expanded != out { out = expanded; changed = true }
            }
            let substituted = substitute(out, macros)
            if substituted != out { out = substituted; changed = true }
            if !changed || out.utf8.count > maxExpansionBytes { break }
        }
        return out
    }

    /// Whole-word substitution of each object-like macro name with its value, in definition order.
    private static func substitute(_ text: String, _ macros: [(name: String, value: String)]) -> String {
        var out = text
        for macro in macros { out = wholeWordReplace(out, macro.name, macro.value) }
        return out
    }

    /// Expand every call `NAME(args)` of a function-like macro by substituting the parenthesised arguments
    /// for the parameters in its (parenthesised) body. Arguments split on top-level commas so nested calls
    /// survive; a call whose arity doesn't match is left alone rather than mangled.
    private static func expandFunctionMacros(_ text: String, _ macros: [(name: String, params: [String], body: String)]) -> String {
        var s = text
        for macro in macros {
            var from = s.startIndex
            while let r = s.range(of: macro.name, range: from ..< s.endIndex) {
                let precededByWord = r.lowerBound > s.startIndex && {
                    let c = s[s.index(before: r.lowerBound)]; return c.isLetter || c.isNumber || c == "_" || c == "."
                }()
                guard !precededByWord, r.upperBound < s.endIndex, s[r.upperBound] == "(",
                      let (args, close) = callArguments(s, r.upperBound) else { from = r.upperBound; continue }
                guard args.count == macro.params.count else { from = r.upperBound; continue }
                var body = macro.body
                for (param, arg) in zip(macro.params, args) { body = wholeWordReplace(body, param, "(\(arg))") }
                let expansion = "(\(body))"
                s.replaceSubrange(r.lowerBound...close, with: expansion)
                from = s.index(r.lowerBound, offsetBy: expansion.count)
                if s.utf8.count > maxExpansionBytes { return s }   // a reduplicating function macro bomb
            }
        }
        return s
    }

    /// The top-level (balanced-paren) comma-separated arguments of a call whose `(` is at `open`, plus the
    /// index of the matching `)`. A bare `()` yields no arguments.
    private static func callArguments(_ s: String, _ open: String.Index) -> (args: [String], close: String.Index)? {
        var depth = 0, i = open, argStart = s.index(after: open)
        var args: [String] = []
        while i < s.endIndex {
            switch s[i] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    let last = s[argStart..<i].trimmingCharacters(in: .whitespaces)
                    if !(args.isEmpty && last.isEmpty) { args.append(last) }   // () → no args
                    return (args, i)
                }
            case "," where depth == 1:
                args.append(s[argStart..<i].trimmingCharacters(in: .whitespaces)); argStart = s.index(after: i)
            default: break
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// The index of the `)` matching the `(` at `open`, or nil if unbalanced.
    private static func matchingParen(_ s: String, _ open: String.Index) -> String.Index? {
        var depth = 0, i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    /// Replace whole-word occurrences of `word` with `replacement` (not part of a larger identifier, not
    /// after a `.`), repeated to a fixed point so a chain of object macros fully resolves.
    private static func wholeWordReplace(_ text: String, _ word: String, _ replacement: String) -> String {
        let pattern = "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: word))(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let grow = max(0, replacement.utf8.count - word.utf8.count)
        for _ in 0..<8 {
            let range = NSRange(out.startIndex..., in: out)
            let matches = regex.numberOfMatches(in: out, range: range)
            guard matches > 0 else { break }
            // A single `stringByReplacingMatches` expands EVERY occurrence in one allocation, so a macro
            // whose value is large and occurs many times could allocate gigabytes before the post-pass size
            // check below ever runs. Project the resulting size first and stop early if it would blow past
            // the cap — leaving the text un-substituted (graceful) rather than risking an out-of-memory abort.
            guard out.utf8.count + matches * grow <= maxExpansionBytes else { break }
            let replaced = regex.stringByReplacingMatches(in: out, range: range,
                                                          withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            if replaced == out { break }
            out = replaced
            if out.utf8.count > maxExpansionBytes { break }   // a doubling macro (`#define X X X`) bomb
        }
        return out
    }

    /// Replace each `#include "name"` (or `<name>`) line with the source of `includes[name]`, recursively
    /// (a header may include another). A header already on the include path is skipped so a cycle
    /// terminates; an unknown header is left in place (later dropped as a `#` line, exactly as before).
    static func expandIncludes(_ source: String, _ includes: [String: String]) -> String {
        func expand(_ text: String, _ onPath: Set<String>) -> String {
            var out: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#include"), let name = includeName(line) {
                    if onPath.contains(name) { continue }                       // cycle — drop
                    if let header = includes[name] { out.append(expand(header, onPath.union([name]))); continue }
                }
                out.append(line)
            }
            return out.joined(separator: "\n")
        }
        return expand(source, [])
    }

    /// The header name inside an `#include "name"` / `#include <name>` directive.
    private static func includeName(_ line: String) -> String? {
        guard let open = line.firstIndex(where: { $0 == "\"" || $0 == "<" }) else { return nil }
        let after = line.index(after: open)
        guard let close = line[after...].firstIndex(where: { $0 == "\"" || $0 == ">" }) else { return nil }
        return after < close ? String(line[after..<close]) : nil
    }

    /// Default combo values a shader declares in its `// [COMBO] {…"combo":NAME,"default":N}` header
    /// lines (combo name → default int). These seed the combo set when an effect doesn't override them.
    public static func comboDefaults(_ source: String) -> [String: Int] {
        let source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var defaults: [String: Int] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("// [COMBO]"), let brace = trimmed.firstIndex(of: "{"),
                  let json = (try? JSONSerialization.jsonObject(with: Data(trimmed[brace...].utf8))) as? [String: Any],
                  let name = json["combo"] as? String else { continue }
            defaults[name] = (json["default"] as? NSNumber)?.intValue ?? 0
        }
        return defaults
    }

    /// The condition text of an `#if`/`#ifdef`/`#ifndef` line, normalised to an expression. A trailing
    /// `//`/`/*` comment is stripped first (GLSL/C strip comments before evaluating a directive) — WE's
    /// shaders annotate branches like `#if TYPE == 4 // Cutout square`, and leaving the comment in makes the
    /// right-hand side unparseable so the comparison silently reads as `… == 0` and the branch is mis-taken.
    private static func condition(_ line: String) -> String {
        let line = stripTrailingComment(line).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#ifdef ") { return "defined " + line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("#ifndef ") { return "!defined " + line.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)   // after "#if "
    }

    /// Evaluate a `#if` condition against the combos: `||`, `&&`, `!`, the comparisons `== != <= >= < >`,
    /// `defined NAME`, parentheses, integer literals and bare combo names (missing reads as 0).
    private static func evaluate(_ expression: String, combos: [String: Int], defined: Set<String> = []) -> Bool {
        value(of: expression, combos, defined) != 0
    }

    /// The deepest a `#if` condition sub-expression may nest (parens / leading `!`) before the recursive
    /// evaluator bails. Real conditions nest a handful of levels; this is far above that yet well below the
    /// ~25k-deep nesting that would overflow the call stack on a crafted shader. Mirrors KeyValuesParser.
    private static let maxConditionDepth = 256

    /// The integer value of a condition sub-expression (0 = false, non-zero = true). `depth` bounds the
    /// paren/`!` recursion so an untrusted shader can't blow the stack with deeply nested parentheses.
    private static func value(of expression: String, _ combos: [String: Int], _ defined: Set<String>, _ depth: Int = 0) -> Int {
        guard depth < maxConditionDepth else { return 0 }   // over-nested → drop the branch, never crash
        let expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.isEmpty { return 0 }
        if let parts = splitTopLevel(expr, "||") { return parts.contains { value(of: $0, combos, defined, depth + 1) != 0 } ? 1 : 0 }
        if let parts = splitTopLevel(expr, "&&") { return parts.allSatisfy { value(of: $0, combos, defined, depth + 1) != 0 } ? 1 : 0 }
        for op in ["==", "!=", "<=", ">=", "<", ">"] {
            if let (lhs, rhs) = splitFirstTopLevel(expr, op) {
                let a = value(of: lhs, combos, defined, depth + 1), b = value(of: rhs, combos, defined, depth + 1)
                switch op {
                case "==": return a == b ? 1 : 0
                case "!=": return a != b ? 1 : 0
                case "<=": return a <= b ? 1 : 0
                case ">=": return a >= b ? 1 : 0
                case "<":  return a < b ? 1 : 0
                default:   return a > b ? 1 : 0
                }
            }
        }
        if expr.hasPrefix("!") { return value(of: String(expr.dropFirst()), combos, defined, depth + 1) == 0 ? 1 : 0 }
        if expr.hasPrefix("("), expr.hasSuffix(")") { return value(of: String(expr.dropFirst().dropLast()), combos, defined, depth + 1) }
        if expr.hasPrefix("defined") {
            // A name is defined if it was #define'd (any value, including none) or supplied as a combo.
            let name = expr.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            return defined.contains(name) || combos[name] != nil ? 1 : 0
        }
        if let literal = Int(expr) { return literal }
        return combos[expr] ?? 0
    }

    /// Split `s` on every top-level (paren-depth 0) occurrence of `op`; nil if it appears zero times.
    private static func splitTopLevel(_ s: String, _ op: String) -> [String]? {
        var parts: [String] = [], depth = 0, start = s.startIndex, i = s.startIndex
        while i < s.endIndex {
            switch s[i] {
            case "(": depth += 1; i = s.index(after: i)
            case ")": depth -= 1; i = s.index(after: i)
            case _ where depth == 0 && s[i...].hasPrefix(op):
                parts.append(String(s[start..<i]))
                i = s.index(i, offsetBy: op.count); start = i
            default: i = s.index(after: i)
            }
        }
        parts.append(String(s[start...]))
        return parts.count > 1 ? parts : nil
    }

    /// Split `s` at the first top-level occurrence of `op` into (left, right); nil if absent.
    private static func splitFirstTopLevel(_ s: String, _ op: String) -> (String, String)? {
        var depth = 0, i = s.startIndex
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1 }
            else if depth == 0, s[i...].hasPrefix(op) {
                return (String(s[s.startIndex..<i]), String(s[s.index(i, offsetBy: op.count)...]))
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Resolves a WE shader's `#if`/`#ifdef`/`#elif`/`#else`/`#endif` combo
// conditionals against the combo values an effect selects, keeping only the active branches so the
// transpiled shader takes the right code path. Other `#` directives pass through. No GPL.
import Foundation

public enum ShaderPreprocessor {
    /// Keep only the lines in branches that are active for `combos` (a missing combo reads as 0).
    public static func resolve(_ source: String, combos: [String: Int]) -> String {
        // WE shaders ship with Windows CRLF endings. Swift treats "\r\n" as a single grapheme, so
        // split(separator: "\n") would never match it and the whole file would collapse into one
        // "line" — normalise to LF up front so every line-based step downstream works.
        let source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        struct Frame { let parentEmitting: Bool; var taken: Bool; var active: Bool }
        var stack: [Frame] = []
        func emitting() -> Bool { stack.last.map { $0.parentEmitting && $0.active } ?? true }

        var output: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#ifdef ") || trimmed.hasPrefix("#ifndef ") {
                let parent = emitting()
                let value = parent && evaluate(condition(trimmed), combos: combos)
                stack.append(Frame(parentEmitting: parent, taken: value, active: value))
            } else if trimmed.hasPrefix("#elif ") {
                guard var frame = stack.popLast() else { continue }
                frame.active = frame.parentEmitting && !frame.taken && evaluate(String(trimmed.dropFirst(6)), combos: combos)
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
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
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

    /// The condition text of an `#if`/`#ifdef`/`#ifndef` line, normalised to an expression.
    private static func condition(_ line: String) -> String {
        if line.hasPrefix("#ifdef ") { return "defined " + line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("#ifndef ") { return "!defined " + line.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)   // after "#if "
    }

    /// Evaluate a `#if` condition against the combos: `||`, `&&`, `!`, the comparisons `== != <= >= < >`,
    /// `defined NAME`, parentheses, integer literals and bare combo names (missing reads as 0).
    private static func evaluate(_ expression: String, combos: [String: Int]) -> Bool {
        value(of: expression, combos) != 0
    }

    /// The integer value of a condition sub-expression (0 = false, non-zero = true).
    private static func value(of expression: String, _ combos: [String: Int]) -> Int {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.isEmpty { return 0 }
        if let parts = splitTopLevel(expr, "||") { return parts.contains { value(of: $0, combos) != 0 } ? 1 : 0 }
        if let parts = splitTopLevel(expr, "&&") { return parts.allSatisfy { value(of: $0, combos) != 0 } ? 1 : 0 }
        for op in ["==", "!=", "<=", ">=", "<", ">"] {
            if let (lhs, rhs) = splitFirstTopLevel(expr, op) {
                let a = value(of: lhs, combos), b = value(of: rhs, combos)
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
        if expr.hasPrefix("!") { return value(of: String(expr.dropFirst()), combos) == 0 ? 1 : 0 }
        if expr.hasPrefix("("), expr.hasSuffix(")") { return value(of: String(expr.dropFirst().dropLast()), combos) }
        if expr.hasPrefix("defined") {
            return combos[expr.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))] != nil ? 1 : 0
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

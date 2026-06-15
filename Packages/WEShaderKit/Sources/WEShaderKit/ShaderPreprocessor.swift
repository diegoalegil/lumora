// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Resolves a WE shader's `#if`/`#ifdef`/`#elif`/`#else`/`#endif` combo
// conditionals against the combo values an effect selects, keeping only the active branches so the
// transpiled shader takes the right code path. Other `#` directives pass through. No GPL.
import Foundation

public enum ShaderPreprocessor {
    /// Keep only the lines in branches that are active for `combos` (a missing combo reads as 0).
    public static func resolve(_ source: String, combos: [String: Int]) -> String {
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

    /// The condition text of an `#if`/`#ifdef`/`#ifndef` line, normalised to an expression.
    private static func condition(_ line: String) -> String {
        if line.hasPrefix("#ifdef ") { return "defined " + line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("#ifndef ") { return "!defined " + line.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)   // after "#if "
    }

    /// Evaluate `NAME`, `NAME == N`, `NAME != N`, `defined NAME`, `!defined NAME` against the combos.
    private static func evaluate(_ expression: String, combos: [String: Int]) -> Bool {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("defined ") { return combos[String(expr.dropFirst(8)).trimmingCharacters(in: .whitespaces)] != nil }
        if expr.hasPrefix("!defined ") { return combos[String(expr.dropFirst(9)).trimmingCharacters(in: .whitespaces)] == nil }
        for op in ["==", "!="] {
            if let range = expr.range(of: op) {
                let name = String(expr[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = Int(String(expr[range.upperBound...]).trimmingCharacters(in: .whitespaces)) ?? 0
                let value = combos[name] ?? 0
                return op == "==" ? value == rhs : value != rhs
            }
        }
        if let literal = Int(expr) { return literal != 0 }
        return (combos[expr] ?? 0) != 0
    }
}

// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Valve KeyValues (VDF) text format per the public Valve Developer Wiki
// (quoted/unquoted tokens, `{ }` objects, `//` line comments). Steam's libraryfolders.vdf is VDF.
import Foundation

/// A node in a Valve KeyValues (VDF) document: either a leaf string value or an *ordered* list of
/// key→node pairs. Order is preserved because Steam writes positional keys ("0", "1", …) and a
/// dictionary would lose that.
public indirect enum KVNode: Sendable, Equatable {
    case value(String)
    case object([KVPair])
}

/// One key→value entry inside a KeyValues object.
public struct KVPair: Sendable, Equatable {
    public let key: String
    public let value: KVNode

    public init(key: String, value: KVNode) {
        self.key = key
        self.value = value
    }
}

public enum KeyValuesError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedEnd
    case unexpectedToken(String)
    case unterminatedString
    case nestingTooDeep

    public var description: String {
        switch self {
        case .unexpectedEnd:        return "Unexpected end of KeyValues input."
        case .unexpectedToken(let t): return "Unexpected token '\(t)' in KeyValues input."
        case .unterminatedString:   return "Unterminated quoted string in KeyValues input."
        case .nestingTooDeep:       return "KeyValues input nests objects beyond the supported depth."
        }
    }
}

/// A small, dependency-free parser for the subset of Valve KeyValues that Steam uses for its
/// configuration files. It is deliberately lenient about content (any string is a valid key or
/// value) and strict only about structure (balanced braces, a value after every key).
public enum KeyValuesParser {
    /// The deepest object nesting the parser will follow. Real Steam/VDF files nest only a handful of
    /// levels; this ceiling rejects a crafted file of nested `{` well before the recursive descent could
    /// approach a stack-overflow trap — kept low enough to stay safe even on a small-stack worker thread.
    private static let maxNestingDepth = 64
    /// Reject an absurdly large VDF before materializing it: real Steam config files are kilobytes.
    private static let maxInputBytes = 32 << 20   // 32 MB

    /// Parse a KeyValues/VDF document into its top-level object node.
    public static func parse(_ text: String) throws -> KVNode {
        guard text.utf8.count <= maxInputBytes else { throw KeyValuesError.unexpectedEnd }
        var tokenizer = Tokenizer(Array(text.unicodeScalars))
        let pairs = try parsePairs(&tokenizer, expectClose: false, depth: 0)
        return .object(pairs)
    }

    private static func parsePairs(_ tokenizer: inout Tokenizer, expectClose: Bool, depth: Int) throws -> [KVPair] {
        guard depth <= maxNestingDepth else { throw KeyValuesError.nestingTooDeep }
        var pairs: [KVPair] = []
        while true {
            guard let token = try tokenizer.next() else {
                if expectClose { throw KeyValuesError.unexpectedEnd }
                return pairs
            }
            switch token {
            case .close:
                if expectClose { return pairs }
                throw KeyValuesError.unexpectedToken("}")
            case .open:
                throw KeyValuesError.unexpectedToken("{")
            case .string(let key):
                guard let valueToken = try tokenizer.next() else { throw KeyValuesError.unexpectedEnd }
                switch valueToken {
                case .open:
                    let children = try parsePairs(&tokenizer, expectClose: true, depth: depth + 1)
                    pairs.append(KVPair(key: key, value: .object(children)))
                case .string(let value):
                    pairs.append(KVPair(key: key, value: .value(value)))
                case .close:
                    throw KeyValuesError.unexpectedToken("}")
                }
            }
        }
    }

    private enum Token: Equatable {
        case string(String)
        case open
        case close
    }

    private struct Tokenizer {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func next() throws -> Token? {
            skipTrivia()
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "{": index += 1; return .open
            case "}": index += 1; return .close
            case "\"": return .string(try readQuoted())
            default: return .string(readUnquoted())
            }
        }

        private mutating func skipTrivia() {
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    index += 1
                } else if c == "/" && index + 1 < scalars.count && scalars[index + 1] == "/" {
                    index += 2
                    while index < scalars.count && scalars[index] != "\n" { index += 1 }
                } else {
                    break
                }
            }
        }

        private mutating func readQuoted() throws -> String {
            index += 1 // consume opening quote
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c == "\\" {
                    index += 1
                    guard index < scalars.count else { throw KeyValuesError.unterminatedString }
                    switch scalars[index] {
                    case "n":  out.append("\n")
                    case "t":  out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case let other: out.append(other)
                    }
                    index += 1
                } else if c == "\"" {
                    index += 1 // consume closing quote
                    return String(out)
                } else {
                    out.append(c)
                    index += 1
                }
            }
            throw KeyValuesError.unterminatedString
        }

        private mutating func readUnquoted() -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "{" || c == "}" || c == "\"" {
                    break
                }
                if c == "/" && index + 1 < scalars.count && scalars[index + 1] == "/" { break }
                out.append(c)
                index += 1
            }
            return String(out)
        }
    }
}

public extension KVNode {
    /// The child pairs of an object node (empty for a leaf value).
    var children: [KVPair] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    /// The string of a leaf value node (`nil` for an object).
    var stringValue: String? {
        if case .value(let s) = self { return s }
        return nil
    }

    /// The value of the first child whose key matches `key`, case-insensitively.
    func first(_ key: String) -> KVNode? {
        children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// The values of all children whose key matches `key`, case-insensitively.
    func all(_ key: String) -> [KVNode] {
        children
            .filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            .map(\.value)
    }
}

// Support for PackCatalogue.swift (ported from
// lib/src/services/packs/pack_catalogue.dart).

import Foundation

/// A JSON value whose objects keep their keys in document order.
///
/// Dart's `jsonDecode` returns insertion-ordered maps, and `PackCatalogue`
/// depends on that: it walks the packs in the order the catalogue lists them,
/// and both its tie-breaks (the first pack holding the most of a subject wins;
/// equal suggestions keep their order through the sort) follow from it.
/// `JSONSerialization` and `JSONDecoder` both lose key order, so reading the
/// catalogue with either would make the two apps disagree on ties.
enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    /// The value for `key` in an object; the last one if the key repeats, as
    /// `jsonDecode` keeps it.
    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ what: String) -> ParseError {
            ParseError(description: "Invalid JSON at byte \(index): \(what)")
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let utf8 = Array(word.utf8)
            guard bytes.count - index >= utf8.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
                throw error("expected \(word)")
            }
            index += utf8.count
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var members: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                members.append((key, try value()))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(validating: out, as: UTF8.self) else { throw error("invalid UTF-8") }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw error("unterminated escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800..<0xDC00).contains(scalar) {
                            // A high surrogate must be followed by \u and a low one.
                            guard bytes.count - index >= 6,
                                  bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                            else { throw error("lone surrogate") }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw error("bad surrogate pair") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw error("bad \\u escape") }
                        out.append(contentsOf: Array(String(Character(unicode)).utf8))
                    default:
                        throw error("bad escape")
                    }
                default:
                    guard byte >= 0x20 else { throw error("control character in string") }
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw error("short \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue else {
                    throw error("bad hex digit")
                }
                value = value * 16 + UInt32(digit)
                index += 1
            }
            return value
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count {
                let byte = bytes[index]
                if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                    index += 1
                } else if [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                           UInt8(ascii: "+"), UInt8(ascii: "-")].contains(byte) {
                    isInteger = false
                    index += 1
                } else {
                    break
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            // Dart reads an integer literal as int and anything with a point or
            // exponent as double, and `as int` rejects the latter.
            if isInteger, let int = Int(text) { return .int(int) }
            guard !text.isEmpty, text != "-", let double = Double(text) else { throw error("bad value") }
            return .double(double)
        }
    }
}

// JSON written as Dart's `jsonEncode` writes it (dart:convert's
// `_JsonStringifier`), for the two places where the bytes matter: citation
// blobs stored in `conversation_messages.citations`, which the Flutter app
// reads back from the same file, and request bodies, which are then
// byte-for-byte what the Flutter app sends.

import Foundation

extension OrderedJSON {
    /// `jsonEncode(value)`: no whitespace, object keys in their given order,
    /// `null` written out rather than omitted.
    ///
    /// Strings are escaped as Dart escapes them (`DartJSON.quoted`).
    ///
    /// Doubles are written with Swift's shortest round-trip form, which agrees
    /// with Dart's for the finite values written here (`0.7`); integral
    /// doubles would differ (`1.0` both ways, but `1e+21` vs `1e21`), so
    /// callers write integers as `.int`.
    var dartEncoded: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += value.isFinite ? "\(value)" : "null"
        case .string(let value): out += DartJSON.quoted(value)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                out += DartJSON.quoted(member.key)
                out += ":"
                member.value.write(to: &out)
            }
            out += "}"
        }
    }

    /// `jsonDecode` of UTF-8 text, or nil when it isn't JSON.
    static func parse(_ text: String) -> OrderedJSON? {
        try? parse(Data(text.utf8))
    }

    /// The string, when this is one; nil for every other type, where a Dart
    /// `as String?` cast would throw.
    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// The integer, when this is one (`as int?`).
    var intValue: Int? {
        if case .int(let value) = self { value } else { nil }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let items) = self { items } else { nil }
    }

    var isObject: Bool {
        if case .object = self { true } else { false }
    }
}

extension DartText {
    /// `String.startsWith`: a code-unit prefix test. Swift's `hasPrefix`
    /// compares by canonical equivalence, so an NFD model name would match an
    /// NFC one here and not in Dart.
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.utf16.starts(with: prefix.utf16)
    }

    /// `String.trimLeft()`.
    static func trimmedLeft(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count && isTrimWhitespace(units[start]) { start += 1 }
        return start == 0 ? text : String(decoding: units[start...], as: UTF16.self)
    }

    /// `String.trimRight()`.
    static func trimmedRight(_ text: String) -> String {
        let units = Array(text.utf16)
        var end = units.count
        while end > 0 && isTrimWhitespace(units[end - 1]) { end -= 1 }
        return end == units.count ? text : String(decoding: units[..<end], as: UTF16.self)
    }
}

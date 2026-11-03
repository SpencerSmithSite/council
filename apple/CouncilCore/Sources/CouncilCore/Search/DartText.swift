// Dart string semantics the search code depends on, reproduced exactly.
//
// Ported alongside lib/src/services/search/*.dart and the query shaping in
// lib/src/services/database_service.dart. Nothing here is Dart-specific in
// spirit; it exists because Swift's String is canonical-equivalence based and
// grapheme-oriented while Dart's is a sequence of UTF-16 code units, and the
// golden fixtures (shared/golden/search) were produced by the Dart behaviour:
//
// - Swift `==`, `hasSuffix` and `Dictionary<String, _>` treat NFC and NFD
//   spellings as equal; Dart compares code units. Where an exact key matters
//   the ports key on code units or scalars instead of `String`.
// - Swift splits `"\r\n"` as one Character; Dart's `split('\n')` splits the
//   code unit.
// - Swift's `lowercased()` uses the full Unicode mapping; the Dart VM maps
//   code point to code point (the simple mapping). They differ on U+0130 'İ',
//   which Swift lowercases to "i" + U+0307 and Dart to "i" — and the entity
//   recogniser's tokeniser splits on that U+0307, so "İstanbul" would come
//   out as two words here and one in Dart.

enum DartText {
    /// `String.toLowerCase()` as the Dart VM does it: each code point mapped to
    /// a single code point.
    static func lowercased(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append(lowercased(scalar))
        }
        return String(out)
    }

    static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.value < 0x80 {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                return Unicode.Scalar(scalar.value + 0x20)!
            }
            return scalar
        }
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        if mapped.count == 1 { return mapped.first! }
        // The one unconditional multi-scalar lowercase mapping is U+0130,
        // whose simple mapping is plain "i".
        if scalar.value == 0x130 { return "i" }
        return scalar
    }

    /// The code units Dart's `String.trim`/`trimRight` treat as whitespace.
    static func isTrimWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.trim()`.
    static func trimmed(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0
        var end = units.count
        while start < end && isTrimWhitespace(units[start]) { start += 1 }
        while end > start && isTrimWhitespace(units[end - 1]) { end -= 1 }
        if start == 0 && end == units.count { return text }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// The part of `units[range]` that `String.trim()` keeps, as offsets into
    /// `units`. Empty (and positioned at the range's end) when everything is
    /// whitespace. `trimLeft`/`trimRight` use the same set, so the lower bound
    /// is where `trimLeft` would start and the upper bound where `trimRight`
    /// would end.
    static func trimmedBounds(_ units: [UInt16], _ range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end && isTrimWhitespace(units[start]) { start += 1 }
        while end > start && isTrimWhitespace(units[end - 1]) { end -= 1 }
        return start..<end
    }

    /// `\s` in a Dart (ECMAScript) regular expression: WhiteSpace plus
    /// LineTerminator. Not the same set as `trim` — U+0085 is absent.
    static func isRegExpWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `\s` tested against one UTF-16 code unit, which is how a Dart RegExp
    /// without the `unicode` flag reads its input. Every member of the set is
    /// in the BMP and none is a surrogate, so this agrees with the scalar
    /// version on any well-formed string.
    static func isRegExpWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return isRegExpWhitespace(scalar)
    }

    /// `\d` in a Dart RegExp: ASCII `0-9` only, with or without the `unicode`
    /// flag. ICU's `\d` (NSRegularExpression) is `\p{Nd}`, which also takes
    /// Arabic-Indic, Devanagari, fullwidth and every other script's digits.
    static func isRegExpDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    /// Code-unit equality, which is what Dart's `==` on strings is.
    static func equal(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }
}

/// A `String` that hashes and compares by UTF-16 code units, as a Dart map key
/// does, rather than by canonical equivalence.
struct ExactString: Hashable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    static func == (lhs: ExactString, rhs: ExactString) -> Bool {
        DartText.equal(lhs.value, rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        for unit in value.utf16 { hasher.combine(unit) }
    }
}

/// An insertion-ordered set: the iteration order of a Dart `Set` literal or
/// `<T>{}`, which is a `LinkedHashSet`. Several outputs (labels, tag slugs,
/// the order traditions are visited in) are defined by that order.
struct OrderedSet<Element: Hashable>: Sequence {
    private(set) var elements: [Element] = []
    private var members: Set<Element> = []

    init() {}

    init(_ items: some Sequence<Element>) {
        for item in items { insert(item) }
    }

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    func contains(_ item: Element) -> Bool { members.contains(item) }

    /// Returns whether `item` was newly added, like Dart's `Set.add`.
    @discardableResult
    mutating func insert(_ item: Element) -> Bool {
        guard members.insert(item).inserted else { return false }
        elements.append(item)
        return true
    }

    mutating func insert(contentsOf items: some Sequence<Element>) {
        for item in items { insert(item) }
    }

    mutating func remove(contentsOf items: some Sequence<Element>) {
        var removed = false
        for item in items where members.remove(item) != nil { removed = true }
        if removed { elements.removeAll { !members.contains($0) } }
    }

    func makeIterator() -> IndexingIterator<[Element]> { elements.makeIterator() }
}

extension OrderedSet: Sendable where Element: Sendable {}

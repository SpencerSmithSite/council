// Where a search's words fall in a passage it found. Native-only: the Flutter
// Read tab lists results with the first 160 characters of each unit and marks
// nothing, so there is no Dart to mirror.

import Foundation

/// The words a lexical search matched, and where they fall in a passage.
///
/// The search screen bolds them in each result's snippet, and the reader marks
/// them when it opens at a result, so a reader who searched "propitiation"
/// lands on the word rather than at the top of a chapter that contains it
/// somewhere.
///
/// This re-finds the words in Swift rather than asking FTS5 (`highlight()`,
/// `snippet()`), because the search query is shared with the Flutter app and
/// held to `shared/golden/search` column for column; marking is a display
/// concern and can afford to approximate. It follows what each path actually
/// matched:
///
/// - **FTS5**: the query's terms (`QueryShaping.ftsTerms`), each a *prefix*
///   of a word, compared the way the `unicode61` tokenizer compares: case
///   folded and diacritics removed, so "gregoire" marks "Grégoire" and "grac"
///   marks "grace" and "gracious". The whole word is marked.
/// - **LIKE**: the trimmed query as one phrase, anywhere, case-insensitively.
///   SQLite's LIKE folds ASCII case only, so this can mark a non-ASCII
///   case variant LIKE didn't match; it never misses one LIKE did.
///
/// Offsets are UTF-16 code units into the unit's content, as segments and
/// highlights are.
public struct SearchHits: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case prefixes([String])
        case phrase(String)
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    /// The hits for `query` as the search that ran answered it: the path of
    /// the last query `search` ran (`like` after an FTS query found nothing).
    public init(query: String, search: LexicalSearch) {
        if search.calls.last?.kind == .like {
            mode = .phrase(DartText.trimmed(query))
        } else {
            mode = .prefixes(QueryShaping.ftsTerms(query))
        }
    }

    public var isEmpty: Bool {
        switch mode {
        case .prefixes(let terms): terms.isEmpty
        case .phrase(let phrase): phrase.isEmpty
        }
    }

    /// Every hit in `content`, in order and not overlapping.
    public func ranges(in content: String) -> [Range<Int>] {
        switch mode {
        case .prefixes(let terms):
            let folded = terms.map(Self.fold).filter { !$0.isEmpty }
            guard !folded.isEmpty else { return [] }
            return Self.words(in: content).filter { word in
                let token = Self.fold(word.text)
                return folded.contains { token.hasPrefix($0) }
            }.map(\.range)
        case .phrase(let phrase):
            guard !phrase.isEmpty else { return [] }
            let string = content as NSString
            var out: [Range<Int>] = []
            var from = 0
            while from < string.length {
                let found = string.range(of: phrase, options: [.caseInsensitive],
                                         range: NSRange(location: from, length: string.length - from))
                guard found.location != NSNotFound, found.length > 0 else { break }
                out.append(found.location..<NSMaxRange(found))
                from = NSMaxRange(found)
            }
            return out
        }
    }

    // MARK: - Words

    /// Case folded and without diacritics, as `unicode61` compares tokens.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of `content` as `unicode61` splits them: runs of letters,
    /// numbers and combining marks, everything else a separator. A mark
    /// belongs to the word it sits on, so a decomposed "Nicée" is one word
    /// here (FTS5 strips the mark when it folds) where `ftsTerms` splits it.
    static func words(in content: String) -> [(text: String, range: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var offset = 0
        var start: Int?
        var current = String.UnicodeScalarView()
        for scalar in content.unicodeScalars {
            if isWordScalar(scalar) {
                if start == nil { start = offset }
                current.append(scalar)
            } else if let begun = start {
                out.append((String(current), begun..<offset))
                start = nil
                current = String.UnicodeScalarView()
            }
            offset += scalar.utf16.count
        }
        if let begun = start { out.append((String(current), begun..<offset)) }
        return out
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}

/// The line a search result shows: the segment holding the first hit (a
/// verse, a paragraph, a sentence of a long one), cut down around the hit
/// when it is long, with the hits inside it.
///
/// A verse is the unit a reader recognises ("16 For God so loved…"), where
/// the first 160 characters of the chapter, which is what Flutter shows,
/// is usually verse 1 whatever the search was for.
public struct SearchSnippet: Sendable, Hashable {
    /// The segment's number when it has one (a verse), shown before the text.
    public let number: Int?
    public let text: String
    /// The hits, as UTF-16 offsets into `text`.
    public let hits: [Range<Int>]
    /// Whether text was cut off before or after.
    public let leadingEllipsis: Bool
    public let trailingEllipsis: Bool

    /// Longer segments are cut to about this many UTF-16 units around the
    /// first hit: two or three lines in a list row.
    public static let defaultLength = 200

    public init(content: String, passage: SegmentedPassage, hits: [Range<Int>],
                maxLength: Int = SearchSnippet.defaultLength) {
        let first = hits.first
        let segment = first.flatMap { hit in
            passage.segments.first { $0.overlaps(hit.lowerBound, hit.upperBound) }
        } ?? passage.segments.first

        guard let segment else {
            number = nil
            text = ""
            self.hits = []
            leadingEllipsis = false
            trailingEllipsis = false
            return
        }

        // Where the segment's text begins in the content: its text is the
        // trimmed run ending at `end` (a verse's starts after its number).
        let units = Array(segment.text.utf16)
        let textStart = segment.end - units.count

        var lower = 0
        var upper = units.count
        if units.count > maxLength {
            // Start a little before the hit, so it reads in context, and
            // snap both ends to spaces so no word is cut in half.
            let hitStart = (first?.lowerBound ?? textStart) - textStart
            lower = max(0, min(hitStart - maxLength / 4, units.count - maxLength))
            upper = min(units.count, lower + maxLength)
            lower = Self.snap(lower, in: units, forward: true)
            upper = Self.snap(upper, in: units, forward: false)
            if upper <= lower { lower = 0; upper = min(units.count, maxLength) }
        }

        number = segment.number
        text = String(decoding: units[lower..<upper], as: UTF16.self)
        self.hits = hits.compactMap { hit in
            let start = max(hit.lowerBound - textStart, lower)
            let end = min(hit.upperBound - textStart, upper)
            return start < end ? (start - lower)..<(end - lower) : nil
        }
        leadingEllipsis = lower > 0
        trailingEllipsis = upper < units.count
    }

    /// `index` moved to just past a space (forward) or onto one (backward),
    /// unless the text has no space within a few words of it.
    private static func snap(_ index: Int, in units: [UInt16], forward: Bool) -> Int {
        guard index > 0, index < units.count else { return index }
        let space: UInt16 = 0x20
        let reach = 24
        if forward {
            var i = index
            while i < min(units.count, index + reach) {
                if units[i - 1] == space { return i }
                i += 1
            }
        } else {
            var i = index
            while i > max(0, index - reach) {
                if units[i] == space { return i }
                i -= 1
            }
        }
        return index
    }
}

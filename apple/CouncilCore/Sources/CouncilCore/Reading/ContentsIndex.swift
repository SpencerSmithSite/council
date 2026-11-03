// Port of the pure logic in `_ContentsSheetState`,
// lib/src/screens/source_reader_screen.dart: the source reader's jump list.
//
// Jump to a section.
//
// A flat list works for a confession of forty articles and fails completely
// for a Bible: scrolling 1,189 undifferentiated rows to reach Habakkuk is not
// navigation. So the sheet filters, and it groups when grouping helps.
//
// The grouping is derived from the titles rather than from a Scripture-aware
// special case — "Genesis 1", "Genesis 2" share a stem, and so do "Session 4"
// and "Session 5". Nothing here knows what a Bible is, which means it also
// works for the next long work with numbered parts.
//
// Strings are handled as Dart handles them — code-unit comparison, Dart's
// `toLowerCase`, `trim` and RegExp `\s`/`\d` — so the native sheet groups,
// filters and labels a work exactly as the Flutter one did.

/// The sections of a work, as the jump list presents them.
public struct ContentsIndex: Sendable {
    /// One stem and the sections under it, in their order in the work.
    public struct Group: Sendable, Hashable {
        public let stem: String
        public let members: [Int]
    }

    /// The sections' titles, nil where a section has none.
    public let titles: [String?]

    /// Whether this work is shown as books-with-chapter-chips or as a flat
    /// list.
    ///
    /// Decided once, from the *whole* work, rather than per keystroke from
    /// whatever the filter currently matches. Measuring the filtered set made
    /// the presentation depend on the query: "prove" matches Proverbs' 31
    /// chapters and grouped, while "Corinth" matches 29 and fell back to a flat
    /// list — so the same Bible changed shape depending on which book you went
    /// looking for. Whether a work *has* books is a fact about the work, not
    /// about the search.
    public let groups: Bool

    private let stems: [String]

    public init(titles: [String?]) {
        self.titles = titles
        stems = titles.map { Self.stem(of: $0 ?? "") }
        groups = Self.shouldGroup(stemCount: Set(stems.map(ExactString.init)).count,
                                  sectionCount: titles.count)
    }

    /// Only worth grouping when it collapses the list substantially. Sixty-six
    /// groups over 1,189 chapters is navigation; 190 groups over 196 questions
    /// is the same list with headings in it.
    static let usefulRatio = 0.5

    /// Grouping needs more than 30 sections, and at most half as many distinct
    /// stems as sections.
    public static func shouldGroup(titles: [String?]) -> Bool {
        ContentsIndex(titles: titles).groups
    }

    private static func shouldGroup(stemCount: Int, sectionCount: Int) -> Bool {
        sectionCount > 30 && Double(stemCount) <= Double(sectionCount) * usefulRatio
    }

    /// The title with any trailing number removed: "Genesis 12" -> "Genesis".
    ///
    /// Dart's `replaceFirst(RegExp(r'\s+\d+\s*$'), '').trim()`. The leftmost
    /// match of that pattern starts at the beginning of the whitespace run
    /// before the final run of ASCII digits, so it is found by walking back
    /// from the end: trailing `\s`, digits, then at least one `\s`. Only the
    /// last number goes ("Psalm 1 2" -> "Psalm 1"), and a number not set off by
    /// whitespace stays ("Part2").
    public static func stem(of title: String) -> String {
        let units = Array(title.utf16)
        var i = units.count
        while i > 0 && DartText.isRegExpWhitespace(units[i - 1]) { i -= 1 }
        let digitsEnd = i
        while i > 0 && DartText.isRegExpDigit(units[i - 1]) { i -= 1 }
        let digitsStart = i
        while i > 0 && DartText.isRegExpWhitespace(units[i - 1]) { i -= 1 }
        guard digitsStart < digitsEnd, i < digitsStart else { return DartText.trimmed(title) }
        return DartText.trimmed(String(decoding: units[0..<i], as: UTF16.self))
    }

    /// The stem of section `index`, nil titles counting as empty.
    public func stem(at index: Int) -> String {
        stems.indices.contains(index) ? stems[index] : ""
    }

    /// The sections whose title contains `filter`, case-insensitively, in
    /// order; every section when the filter is blank. The filter is trimmed
    /// and both sides lowercased as Dart lowercases them, and containment is by
    /// code unit, as Dart's `contains` is.
    public func matching(_ filter: String) -> [Int] {
        let query = Array(DartText.lowercased(DartText.trimmed(filter)).utf16)
        guard !query.isEmpty else { return Array(titles.indices) }
        return titles.indices.filter { index in
            Self.contains(Array(DartText.lowercased(titles[index] ?? "").utf16), query)
        }
    }

    /// `indices` grouped by stem: groups in the order their first member
    /// appears, so books stay in canonical order rather than whatever order a
    /// hash map hands back; members in the order given.
    public func grouped(_ indices: [Int]) -> [Group] {
        var order: [ExactString] = []
        var members: [ExactString: [Int]] = [:]
        for index in indices {
            let stem = ExactString(stem(at: index))
            if members[stem] == nil { order.append(stem) }
            members[stem, default: []].append(index)
        }
        return order.map { Group(stem: $0.value, members: members[$0] ?? []) }
    }

    /// What a flat-list row shows: the title, or "Section n" (counting from 1)
    /// for a section without one. An empty title stays empty, as it does in
    /// Dart, which only substitutes for a null.
    public func title(at index: Int) -> String {
        guard titles.indices.contains(index) else { return "Section \(index + 1)" }
        return titles[index] ?? "Section \(index + 1)"
    }

    /// Inside "Genesis" a chip should read "12", not "Genesis 12".
    ///
    /// Dart's `title.substring(stem.length).trim()`, falling back to the whole
    /// title when that is empty. The stem's length is taken off the *front* of
    /// the untrimmed title, so a title with leading whitespace loses the wrong
    /// characters ("  Genesis 12" gives "is 12"); that is reproduced, not
    /// fixed. Where the cut would fall inside a surrogate pair, the half pair
    /// decodes as U+FFFD (Dart would keep the lone surrogate).
    public func label(for index: Int, stem: String) -> String {
        let title = titles.indices.contains(index) ? titles[index] ?? "" : ""
        let units = Array(title.utf16)
        let cut = stem.utf16.count
        guard cut <= units.count else { return title }
        let short = DartText.trimmed(String(decoding: units[cut...], as: UTF16.self))
        return short.isEmpty ? title : short
    }

    private static func contains(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}

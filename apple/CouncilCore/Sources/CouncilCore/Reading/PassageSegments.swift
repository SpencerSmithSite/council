// Port of lib/src/reader/passage_segments.dart (`segmentPassage`,
// `referenceFor`, `quoteFor`, `SegmentedPassage.noun`).
//
// Golden fixture: shared/golden/segments/segments.json, written by
// test/segments_golden_test.dart. Its README lists the traps.
//
// Splitting a passage into the pieces a reader can tap.
//
// The right piece depends on what the text is. Scripture in this corpus is
// stored one numbered verse per line — `1. In the beginning…` — and a verse is
// unarguably the unit someone means to select. Prose has no such markers, so
// paragraphs serve, except that a paragraph can run to several hundred words,
// at which point "select the paragraph" is no longer a useful thing to offer
// and sentences are.
//
// Nothing here knows what a Bible is. It knows what a numbered line looks
// like, which is also true of numbered canons and articles.
//
// Why this works on UTF-16 code units and not on Swift's `String`: highlights
// and notes are stored in the user database as `start`/`end` offsets into the
// content unit, and the Flutter app wrote them as Dart string indices, which
// are UTF-16 code units. The native app reads those same rows, so every offset
// here has to be the Dart one, and so does every length compared against a
// threshold (`text.trim().length <= 700` counts an emoji as 2).
//
// Why the three regular expressions are hand-written scanners rather than
// NSRegularExpression: ICU and Dart disagree on exactly the classes these
// patterns use. ICU's `\d` takes every script's digits (Dart's is ASCII), its
// `\s` includes U+0085 and excludes U+FEFF (Dart's is the reverse), and its
// multiline `^` also matches after U+0085, U+000B and U+000C (Dart's only after
// \n, \r, U+2028 and U+2029). Each scanner below reproduces Dart's `allMatches`
// for its one pattern — leftmost match first, greedy, resuming at the previous
// match's end — and says which pattern it is.

/// How the passage was divided, which the reader is told so the interface can
/// say "3 verses" rather than "3 selected".
public enum SegmentKind: String, Sendable, Hashable {
    case verse, paragraph, sentence
}

/// One tappable piece of a passage.
public struct PassageSegment: Sendable, Hashable, Identifiable {
    /// Position in the passage, counting from zero. This is what selection
    /// state and rendering key off.
    public let index: Int

    /// UTF-16 offsets into the *unit's* content, so an annotation made here
    /// can be stored against the passage rather than against this parse of it.
    /// For a verse, `start` is where the line's marker begins — the number
    /// included, so highlighting a verse colours its number too.
    public let start: Int
    public let end: Int

    /// The text itself, trimmed — and, for a numbered segment, *without* the
    /// number. The marker is rendered separately and is not part of what gets
    /// quoted: nobody pastes "4. and they encamped against them" into a note.
    public let text: String

    /// The verse (or article) number, when the segment carried one. Nil for
    /// prose, where a segment has no name of its own.
    public let number: Int?

    public var id: Int { index }

    public init(index: Int, start: Int, end: Int, text: String, number: Int? = nil) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.number = number
    }

    /// Whether `start..<end` (UTF-16 offsets, like a stored highlight) shares
    /// any code unit with this segment.
    public func overlaps(_ start: Int, _ end: Int) -> Bool {
        self.start < end && start < self.end
    }
}

public struct SegmentedPassage: Sendable, Hashable {
    public let segments: [PassageSegment]
    public let kind: SegmentKind

    public init(segments: [PassageSegment], kind: SegmentKind) {
        self.segments = segments
        self.kind = kind
    }

    /// Divide `content` into the pieces a reader can select
    /// (Dart's `segmentPassage`).
    public init(_ content: String) {
        self = PassageSegmenter(content).segment()
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// "verse" / "verses", "paragraph" / "paragraphs", … Plural for every
    /// count but exactly 1, zero included.
    public func noun(_ count: Int) -> String {
        let singular = switch kind {
        case .verse: "verse"
        case .paragraph: "paragraph"
        case .sentence: "sentence"
        }
        return count == 1 ? singular : singular + "s"
    }
}

public enum PassageCitation {
    /// How a selection should be cited: "Genesis 1:4–6", "Genesis 1:4, 9", or
    /// for prose simply the section's own title (Dart's `referenceFor`).
    ///
    /// Contiguous runs are collapsed to a range because that is how anyone
    /// writes a reference down, and a reader selecting nine verses does not
    /// want nine numbers listed back at them. Two adjacent verses are written
    /// "4, 5", not "4–5". Numbers are de-duplicated and sorted, so the order
    /// of `selected` does not matter.
    public static func reference(unitTitle: String?, selected: [PassageSegment]) -> String {
        let title = DartText.trimmed(unitTitle ?? "")
        let numbers = Set(selected.compactMap(\.number)).sorted()
        guard let first = numbers.first else { return title }

        // A selection that also takes in an unnumbered segment cannot be cited
        // by verse number, because the quote would then contain text the
        // reference does not cover. The common case is a chapter heading above
        // verse 1: selecting both produced the quote "THE FIRST BOOK OF MOSES
        // In the beginning." under the reference "Genesis 1:1", and that pair
        // is what goes to the clipboard, the share sheet, a saved note, and the
        // model as a pinned passage. The title alone is less precise and it is
        // true, which is the right way round for a citation — the same
        // reasoning as the ellipsis in `quote`.
        if selected.contains(where: { $0.number == nil }) { return title }

        var parts: [String] = []
        var runStart = first
        var previous = first

        func closeRun() {
            if runStart == previous {
                parts.append("\(runStart)")
            } else if previous == runStart + 1 {
                parts.append("\(runStart), \(previous)")
            } else {
                parts.append("\(runStart)\u{2013}\(previous)")
            }
        }

        for number in numbers.dropFirst() {
            if number == previous + 1 {
                previous = number
                continue
            }
            closeRun()
            runStart = number
            previous = number
        }
        closeRun()

        let verses = parts.joined(separator: ", ")
        return title.isEmpty ? verses : "\(title):\(verses)"
    }

    /// The selected text, joined as it would be quoted (Dart's `quoteFor`).
    ///
    /// Verses run together with a space, the way a quoted passage reads; prose
    /// keeps its paragraph breaks. A gap in the selection is marked with an
    /// ellipsis rather than silently closed, because quoting verses 4 and 9 as
    /// though they were consecutive misrepresents the text. Indices are sorted
    /// first; a repeated index counts as a gap, as it does in Dart.
    ///
    /// An index outside the passage is skipped. Dart throws a RangeError
    /// there; a stale selection should not crash the reader.
    public static func quote(_ passage: SegmentedPassage, selected: some Collection<Int>) -> String {
        let indices = selected.filter { passage.segments.indices.contains($0) }.sorted()
        guard !indices.isEmpty else { return "" }

        let joiner = passage.kind == .verse ? " " : "\n\n"
        var out = ""
        for (position, index) in indices.enumerated() {
            if position > 0 {
                out += index == indices[position - 1] + 1 ? joiner : joiner + "\u{2026} "
            }
            out += passage.segments[index].text
        }
        return out
    }
}

// MARK: - Segmentation

/// The Dart file's private functions, over the content's UTF-16 code units.
struct PassageSegmenter {
    /// A paragraph longer than this (trimmed, in UTF-16 code units) is split
    /// at sentence boundaries instead.
    ///
    /// Chosen so that a confessional article — typically one dense paragraph
    /// of two or three hundred characters — stays whole and selectable in a
    /// single tap, while a page-long stretch of Augustine becomes something a
    /// reader can pick a line out of.
    static let paragraphSplitThreshold = 700

    /// The longest a numbered run can be and still read as a verse or an
    /// article.
    ///
    /// Measured against the shipped corpus rather than guessed. For the source
    /// types that genuinely are numbered — Scripture, Confession, Council,
    /// Catechism, Encyclical, Liturgy — the median numbered run is 130 to 344
    /// characters, and the 99th percentile of those medians is 213. For the
    /// prose types, Commentary, Father, Sermon and Treatise, the 25th
    /// percentile is 651 and the median 1,319. 400 sits in the gap, and the
    /// gap is wide.
    static let maxNumberedRunLength = 400

    private let units: [UInt16]

    init(_ content: String) {
        units = Array(content.utf16)
    }

    func segment() -> SegmentedPassage {
        if DartText.trimmedBounds(units, 0..<units.count).isEmpty {
            return SegmentedPassage(segments: [], kind: .paragraph)
        }
        if let verses = verses() {
            return SegmentedPassage(segments: verses, kind: .verse)
        }
        return prose()
    }

    private func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    // MARK: Verses

    /// One match of `^[ \t]*(\d{1,3})\.[ \t]+` (multiLine): `start` is the
    /// line start, `end` is past the spaces after the stop.
    private struct Marker {
        let start: Int
        let end: Int
        let number: Int?
    }

    /// Where Dart's multiline `^` matches: the start of the input and after
    /// each ECMAScript LineTerminator — \n, \r, U+2028, U+2029. Not after
    /// U+0085, U+000B or U+000C, all of which ICU's multiline `^` accepts.
    private static func isLineTerminator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func isSpaceOrTab(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// The marker beginning at line start `lineStart`, if there is one.
    ///
    /// No backtracking is needed: `[ \t]*` giving back a space leaves a space
    /// where a digit is required, and `\d{1,3}` giving back a digit leaves a
    /// digit where the stop is required. So a four-digit number is no marker
    /// at all, and neither is `1.` followed by a no-break space.
    private func marker(at lineStart: Int) -> Marker? {
        var i = lineStart
        while i < units.count && Self.isSpaceOrTab(units[i]) { i += 1 }
        let digitsStart = i
        while i < units.count && i - digitsStart < 3 && DartText.isRegExpDigit(units[i]) { i += 1 }
        let digitsEnd = i
        guard digitsEnd > digitsStart, i < units.count, units[i] == 0x2E else { return nil }
        i += 1
        guard i < units.count, Self.isSpaceOrTab(units[i]) else { return nil }
        while i < units.count && Self.isSpaceOrTab(units[i]) { i += 1 }
        // `int.tryParse` on one to three ASCII digits: always a number, with
        // leading zeros ignored ("007" is 7).
        return Marker(start: lineStart, end: i, number: Int(string(digitsStart..<digitsEnd)))
    }

    /// Every marker, in order. A marker holds no line terminator, so trying
    /// each line start in turn is the same as Dart resuming after each match.
    private func markers() -> [Marker] {
        var found: [Marker] = []
        var lineStart = 0
        while true {
            if let match = marker(at: lineStart) { found.append(match) }
            var i = lineStart
            while i < units.count && !Self.isLineTerminator(units[i]) { i += 1 }
            guard i < units.count else { return found }
            lineStart = i + 1
        }
    }

    /// Verses, or nil when the passage is not numbered like that.
    ///
    /// Two markers are required before this is believed. A single leading
    /// `1.` is as likely to be a list item, or the opening of an enumerated
    /// argument, as it is the start of a numbered text.
    private func verses() -> [PassageSegment]? {
        let matches = markers()
        guard matches.count >= 2 else { return nil }

        // Two markers are not enough on their own. A sermon that enumerates
        // two points, or a commentary listing three objections, matches the
        // pattern as readily as a psalm does — and 23,143 of the corpus's
        // 99,651 non-scripture units once came through here as "verses", with
        // fabricated verse numbers in every citation taken from them. What
        // separates the two is how much text a number governs: a verse or a
        // confessional article is short, a numbered point in an argument
        // carries paragraphs. The median is the upper one for an even count
        // (Dart's `runs[runs.length ~/ 2]`).
        var runs: [Int] = []
        for (i, match) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].start : units.count
            runs.append(end - match.end)
        }
        runs.sort()
        if runs[runs.count / 2] > Self.maxNumberedRunLength { return nil }

        var segments: [PassageSegment] = []

        /// `start` is where the segment begins for annotation purposes — the
        /// number included. `textStart` is where the words begin. `start` is
        /// not trimmed, so a verse's span includes the line's indentation, and
        /// a heading's starts at 0 whatever whitespace precedes it.
        func add(_ start: Int, _ textStart: Int, _ end: Int, _ number: Int?) {
            let text = DartText.trimmedBounds(units, textStart..<end)
            guard !text.isEmpty else { return }
            segments.append(PassageSegment(index: segments.count, start: start,
                                           end: text.upperBound, text: string(text),
                                           number: number))
        }

        // Numbered text that does not *begin* numbered — a chapter heading
        // above verse 1, say — would put everything before the first marker
        // into no segment at all. Give it one.
        if matches[0].start > 0 { add(0, 0, matches[0].start, nil) }

        for (i, match) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].start : units.count
            add(match.start, match.end, end, match.number)
        }

        return segments.isEmpty ? nil : segments
    }

    // MARK: Prose

    /// Paragraphs, with over-long ones broken into sentences.
    private func prose() -> SegmentedPassage {
        var segments: [PassageSegment] = []
        var sawSplitParagraph = false

        func add(_ start: Int, _ end: Int) {
            let text = DartText.trimmedBounds(units, start..<end)
            guard !text.isEmpty else { return }
            segments.append(PassageSegment(index: segments.count, start: text.lowerBound,
                                           end: text.upperBound, text: string(text)))
        }

        for block in blocks() {
            if DartText.trimmedBounds(units, block).count <= Self.paragraphSplitThreshold {
                add(block.lowerBound, block.upperBound)
                continue
            }

            sawSplitParagraph = true
            var cursor = block.lowerBound
            for boundary in sentenceBoundaries(in: block) {
                add(cursor, boundary.lowerBound)
                cursor = boundary.upperBound
            }
            add(cursor, block.upperBound)
        }

        if segments.isEmpty {
            // A passage with no blank lines and no sentence ends — a title, a
            // fragment. One segment is still better than none: it can be copied
            // and highlighted.
            add(0, units.count)
        }

        // Reported as sentences only when something actually was split that
        // way; calling a list of whole paragraphs "sentences" would be a lie
        // the count in the toolbar repeats back to the reader.
        return SegmentedPassage(segments: segments,
                                kind: sawSplitParagraph ? .sentence : .paragraph)
    }

    /// Paragraph spans: runs separated by a blank line, or — when the text has
    /// none — by single newlines. Only \n separates: a CRLF blank line is
    /// `\n\r\n`, which `\n[ \t]*\n+` does not match, so CRLF text always falls
    /// back to one paragraph per line (with the \r trimmed off each).
    private func blocks() -> [Range<Int>] {
        let byBlankLine = spans(splitBy: blankLineSeparators())
        if byBlankLine.count > 1 { return byBlankLine }
        return spans(splitBy: newlineRuns())
    }

    /// Dart's `_spansSplitBy`: the gaps between separator matches, empty gaps
    /// dropped.
    private func spans(splitBy separators: [Range<Int>]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var cursor = 0
        for match in separators {
            if match.lowerBound > cursor { spans.append(cursor..<match.lowerBound) }
            cursor = match.upperBound
        }
        if cursor < units.count { spans.append(cursor..<units.count) }
        return spans
    }

    /// Matches of `\n[ \t]*\n+`. Backtracking `[ \t]*` cannot help (it would
    /// leave a space where \n is required), so a match is a \n, spaces and
    /// tabs, then every \n that follows; a further indented blank line after
    /// it starts a fresh attempt.
    private func blankLineSeparators() -> [Range<Int>] {
        var found: [Range<Int>] = []
        var p = 0
        while p < units.count {
            guard units[p] == 0x0A else { p += 1; continue }
            var q = p + 1
            while q < units.count && Self.isSpaceOrTab(units[q]) { q += 1 }
            guard q < units.count, units[q] == 0x0A else { p += 1; continue }
            while q < units.count && units[q] == 0x0A { q += 1 }
            found.append(p..<q)
            p = q
        }
        return found
    }

    /// Matches of `\n+`.
    private func newlineRuns() -> [Range<Int>] {
        var found: [Range<Int>] = []
        var p = 0
        while p < units.count {
            guard units[p] == 0x0A else { p += 1; continue }
            var q = p
            while q < units.count && units[q] == 0x0A { q += 1 }
            found.append(p..<q)
            p = q
        }
        return found
    }

    /// Matches of `(?<=[.!?][")\]]?)\s+(?=[A-Z"“(\[])` inside `block`, which
    /// Dart runs on the block's substring — so neither look-around sees past
    /// the block's ends.
    ///
    /// A sentence end: terminal punctuation, optionally one straight closing
    /// quote or bracket, whitespace, then something that can begin a sentence.
    /// This is a reading aid, not a parser: an occasional wrong split costs a
    /// reader one extra tap. Note what the classes do and don't hold, because
    /// it shows in the fixture: `St. Paul` and `Mr. Smith` *are* split (an
    /// abbreviation followed by a capital is indistinguishable from a sentence
    /// end), while `Gen. 1` is not; the lookahead accepts an opening curly
    /// quote but the lookbehind does not accept a closing one, so `.”` never
    /// ends a sentence; capitals are ASCII `A-Z` only, so Greek or accented
    /// capitals never begin one; and `\s` is Dart's set, with U+FEFF and
    /// without U+0085.
    ///
    /// `\s+` is greedy and a shorter run would leave whitespace in front of the
    /// lookahead, which never matches whitespace, so only the full run is
    /// tried. Positions inside a run fail the lookbehind, which never matches
    /// whitespace either.
    private func sentenceBoundaries(in block: Range<Int>) -> [Range<Int>] {
        func isTerminal(_ unit: UInt16) -> Bool {
            unit == 0x2E || unit == 0x21 || unit == 0x3F            // . ! ?
        }
        func isCloser(_ unit: UInt16) -> Bool {
            unit == 0x22 || unit == 0x29 || unit == 0x5D            // " ) ]
        }
        func canStartSentence(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A)                          // A-Z
                || unit == 0x22 || unit == 0x201C                   // " “
                || unit == 0x28 || unit == 0x5B                     // ( [
        }
        func lookbehind(_ p: Int) -> Bool {
            if p - 1 >= block.lowerBound && isTerminal(units[p - 1]) { return true }
            return p - 2 >= block.lowerBound && isCloser(units[p - 1]) && isTerminal(units[p - 2])
        }

        var found: [Range<Int>] = []
        var p = block.lowerBound
        while p < block.upperBound {
            if DartText.isRegExpWhitespace(units[p]) && lookbehind(p) {
                var q = p
                while q < block.upperBound && DartText.isRegExpWhitespace(units[q]) { q += 1 }
                if q < block.upperBound && canStartSentence(units[q]) {
                    found.append(p..<q)
                    p = q
                    continue
                }
            }
            p += 1
        }
        return found
    }
}

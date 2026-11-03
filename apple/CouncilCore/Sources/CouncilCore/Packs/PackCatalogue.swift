// Ported from lib/src/services/packs/pack_catalogue.dart, plus the two pieces
// of logic in lib/src/services/packs/pack_provider.dart that are not UI state
// (`nameOf`, and `coverageGapsFor`, which is `suggest`).

import Foundation

/// What an uninstalled pack contains.
///
/// Bundled with the app rather than fetched, because the app has to be able to
/// describe what it is missing while offline — which, for an offline-first
/// library, is the normal case.
public struct PackContents: Equatable, Sendable {
    public let name: String
    public let authors: [String]
    public let titles: [String]
    public let tags: [String: Int]

    /// Which traditions have any text at all in here. Kept separately from
    /// `tags` because absence and scarcity are different questions: tags answer
    /// "how much of this subject am I missing", and only this answers "is this
    /// tradition represented on the device at all".
    public let traditions: [String]

    /// Which fragments back this collection. Coverage arithmetic runs over these
    /// rather than over collections, because collections overlap.
    public let fragments: [String]

    public init(
        name: String = "",
        authors: [String] = [],
        titles: [String] = [],
        tags: [String: Int] = [:],
        traditions: [String] = [],
        fragments: [String] = []
    ) {
        self.name = name
        self.authors = authors
        self.titles = titles
        self.tags = tags
        self.traditions = traditions
        self.fragments = fragments
    }

    init(json: OrderedJSON) throws {
        guard case .object = json else { throw PackCatalogue.formatError("a pack is not an object") }
        name = try json["name"].map(PackCatalogue.string) ?? ""
        authors = try json["authors"].map(PackCatalogue.strings) ?? []
        titles = try json["titles"].map(PackCatalogue.strings) ?? []
        tags = try json["tags"].map(PackCatalogue.counts) ?? [:]
        traditions = try json["traditions"].map(PackCatalogue.strings) ?? []
        fragments = try json["fragments"].map(PackCatalogue.strings) ?? []
    }
}

/// Why a pack is being suggested for a particular question. Declared in rank
/// order: the sort compares these first.
public enum SuggestionReason: Int, Comparable, Sendable, CaseIterable {
    /// The question names someone whose writing lives in this pack.
    case namesAuthor

    /// The question names a work in this pack.
    case namesWork

    /// The question names a tradition with nothing installed from it.
    ///
    /// Ranked above `coversSubject` because it is a stronger claim. Subject
    /// coverage says an answer would be better; this says an answer would be
    /// given *without the tradition that was asked about* — which, for an app
    /// whose purpose is showing what each tradition taught, is not a shortfall
    /// but a wrong answer.
    case traditionAbsent

    /// Nobody is named, but the pack covers this subject heavily.
    case coversSubject

    public static func < (lhs: SuggestionReason, rhs: SuggestionReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PackSuggestion: Equatable, Sendable {
    public let packID: String
    public let reason: SuggestionReason

    /// The author, work or subject that triggered it, for an explanation the
    /// reader can evaluate rather than take on trust.
    public let detail: String

    public init(packID: String, reason: SuggestionReason, detail: String) {
        self.packID = packID
        self.reason = reason
        self.detail = detail
    }

    public var explanation: String {
        switch reason {
        case .namesAuthor: "You asked about \(detail), whose writings are not installed."
        case .namesWork: "\(detail) is not installed."
        case .traditionAbsent: "You asked about the \(detail) tradition, and none of it is installed."
        case .coversSubject: "This collection covers \(detail) extensively and is not installed."
        }
    }
}

/// Notices when a question would be better answered by content the user does
/// not have.
///
/// The app can only search text it holds, so a library without the fathers
/// answers a question about the Eucharist confidently from confessions alone —
/// well-cited, fluent, and quietly missing most of what was ever written on the
/// subject. For an app whose purpose is showing what each tradition actually
/// taught, silently omitting a tradition is the worst failure available, and
/// splitting the corpus is what made it reachable.
public struct PackCatalogue: Sendable {
    /// The bundled file, `assets/pack_catalogue.json` in the Flutter app.
    public static let bundledFileName = "pack_catalogue.json"

    /// Every collection, in the order the catalogue lists them. The order is
    /// load-bearing: `suggest` walks it, and its tie-breaks follow it.
    public let orderedPacks: [(id: String, contents: PackContents)]

    /// The same collections by id.
    public let packs: [String: PackContents]

    /// Tag counts for the bundled corpus, so "how much am I missing" can be
    /// answered as a proportion of everything rather than in the abstract.
    public let core: [String: Int]

    /// What each fragment holds. The unit that actually contains text exactly
    /// once, and therefore the only level at which "do I have this?" can be
    /// answered — collections overlap, so counting over them double-counts, and
    /// asking whether a *collection* is complete answers a different question
    /// entirely from whether an author's text is present.
    public let fragments: [String: PackContents]

    public init(packs: [(id: String, contents: PackContents)], core: [String: Int] = [:], fragments: [String: PackContents] = [:]) {
        self.orderedPacks = packs
        // Last one wins on a repeated id, as a Dart map literal or jsonDecode would.
        self.packs = Dictionary(packs.map { ($0.id, $0.contents) }, uniquingKeysWith: { _, last in last })
        self.core = core
        self.fragments = fragments
    }

    public static func load(from url: URL) throws -> PackCatalogue {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ body: String) throws -> PackCatalogue {
        try parse(Data(body.utf8))
    }

    public static func parse(_ body: Data) throws -> PackCatalogue {
        let json = try OrderedJSON.parse(body)
        guard case .object(let packMembers)? = json["packs"] else {
            throw formatError("the catalogue has no packs object")
        }
        var seen = Set<String>()
        var packs: [(id: String, contents: PackContents)] = []
        // jsonDecode keeps a repeated key at its first position with its last
        // value; `orderedPacks` does the same.
        for (id, value) in packMembers {
            let contents = try PackContents(json: value)
            if seen.insert(id).inserted {
                packs.append((id, contents))
            } else if let at = packs.firstIndex(where: { $0.id == id }) {
                packs[at] = (id, contents)
            }
        }
        let core = try json["core"].map(counts) ?? [:]
        var fragments: [String: PackContents] = [:]
        if let raw = json["fragments"] {
            guard case .object(let members) = raw else { throw formatError("fragments is not an object") }
            for (id, value) in members { fragments[id] = try PackContents(json: value) }
        }
        return PackCatalogue(packs: packs, core: core, fragments: fragments)
    }

    /// The human-readable name of a pack, for a notice that names it. Falls
    /// back to the id. (`PackProvider.nameOf` in Dart.)
    public func name(of packID: String) -> String {
        if let name = packs[packID]?.name, !name.isEmpty { return name }
        return packID
    }

    // MARK: - Matching

    /// A name is only taken as naming a person or work when it appears as whole
    /// words. Substring matching turns "Origen" into a match for "original sin",
    /// which is exactly the sort of thing that trains people to ignore notices.
    ///
    /// Dart builds `\b<needle>\b`, case-insensitive, in a non-Unicode RegExp,
    /// whose `\b` is an *ASCII* word boundary. Swift's `\b` is Unicode-aware and
    /// would disagree next to an accented letter, so the boundary is checked by
    /// hand with Dart's definition: `[A-Za-z0-9_]` is a word character and
    /// nothing else is.
    static func mentions(_ haystack: String, _ needle: String) -> Bool {
        // `needle.length` in Dart counts UTF-16 code units.
        if needle.utf16.count < 4 { return false }
        let hay = Array(haystack.lowercased().unicodeScalars)
        let want = Array(needle.lowercased().unicodeScalars)
        guard let first = want.first, let last = want.last, want.count <= hay.count else { return false }
        for start in 0...(hay.count - want.count) where hay[start..<start + want.count].elementsEqual(want) {
            let before = start > 0 ? hay[start - 1] : nil
            let end = start + want.count
            let after = end < hay.count ? hay[end] : nil
            if isWordBoundary(before, first) && isWordBoundary(last, after) { return true }
        }
        return false
    }

    private static func isASCIIWord(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar, scalar.isASCII else { return false }
        let v = scalar.value
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || v == 0x5F
    }

    private static func isWordBoundary(_ a: Unicode.Scalar?, _ b: Unicode.Scalar?) -> Bool {
        isASCIIWord(a) != isASCIIWord(b)
    }

    /// How a tradition gets named in a question, as against how it is labelled
    /// in the database.
    ///
    /// Nobody types "Reformed" when they mean Presbyterians, or the database's
    /// "Anglican" when they are American and say Episcopalian. Matching the
    /// stored label alone would make this fire almost never, which is the same
    /// as not building it.
    ///
    /// Deliberately conservative: only words that name a tradition and little
    /// else. "Orthodox" is absent because it is far more often an adjective —
    /// "orthodox Christology" is not a question about the Eastern church — and
    /// a notice that misreads the question is worse than no notice.
    static let traditionNames: [(tradition: String, aliases: [String])] = [
        ("Baptist", ["baptist", "baptists"]),
        ("Lutheran", ["lutheran", "lutherans"]),
        ("Reformed", ["reformed", "presbyterian", "presbyterians", "calvinist", "calvinists", "calvinism"]),
        ("Anglican", ["anglican", "anglicans", "episcopalian", "episcopalians"]),
        ("Methodist", ["methodist", "methodists", "wesleyan", "wesleyans"]),
        ("Catholic", ["catholic", "catholics", "catholicism"]),
        ("Eastern Orthodox", ["eastern orthodox", "orthodoxy"]),
    ]

    /// Which traditions `question` names.
    static func traditionsNamed(in question: String) -> Set<String> {
        var named = Set<String>()
        for entry in traditionNames where entry.aliases.contains(where: { mentions(question, $0) }) {
            named.insert(entry.tradition)
        }
        return named
    }

    /// Words that carry no identifying weight in a title, and which nobody is
    /// consistent about when naming one.
    static let filler: Set<String> = ["the", "of", "a", "an", "and", "on", "in", "to", "for", "upon"]

    /// Lower-cased runs of `[a-z0-9]`, longer than two letters, minus filler.
    /// Anything else, accented letters included, separates words, as Dart's
    /// `split(RegExp(r'[^a-z0-9]+'))` does.
    static func significant(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if current.count > 2 {
                let word = String(current)
                if !filler.contains(word) { words.append(word) }
            }
            current = String.UnicodeScalarView()
        }
        for scalar in text.lowercased().unicodeScalars {
            let v = scalar.value
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// Whether `question` names `title`, allowing for the fact that nobody says
    /// a document's full name.
    ///
    /// Requiring the whole title verbatim looked strict-but-safe and was simply
    /// broken: "the Second London Baptist Confession" does not contain "of
    /// Faith", so the confession was never matched, and the same holds for every
    /// anonymous confession in the corpus — which is most of them. Those are
    /// precisely the works with no author to match on instead, so nothing
    /// caught them.
    ///
    /// Three consecutive significant words is the bar. It is specific enough
    /// that no ordinary question stumbles into it — "the doctrine of original
    /// sin" shares no such run with any title here — and loose enough to catch
    /// the short forms people actually use.
    static func namesWork(_ question: String, _ title: String) -> Bool {
        let wanted = significant(title)
        if wanted.count < 3 { return false }
        let asked = significant(question)
        if asked.count < 3 { return false }

        for start in 0...(wanted.count - 3) {
            let run = wanted[start..<start + 3]
            for at in 0...(asked.count - 3) where asked[at..<at + 3].elementsEqual(run) {
                return true
            }
        }
        return false
    }

    /// How much of everything written on a subject must be missing before the
    /// reader is told about it.
    ///
    /// The measure that matters is *what fraction of the corpus's material on
    /// this subject is not installed* — not what fraction of a pack is about it.
    /// Those come apart badly: the Eucharist is 0.2% of Augustine, which sounds
    /// negligible, while the packs together hold most of the corpus's writing on
    /// the Eucharist, which is precisely what a reader needs to know before
    /// trusting an answer.
    ///
    /// **Recalibrated 2026-08-30, from 0.5, because the denominator changed and
    /// not the meaning.** The old value was set when only the patristic units
    /// carried topic tags: `tag_units.py` had never been run over the
    /// Reformation ingest, so 60,000 units of Calvin, Owen, Spurgeon and Matthew
    /// Henry were invisible to this arithmetic. Half of an undercount is not
    /// half of the corpus. With every unit tagged, a reader who has installed
    /// one collection — even the largest — is missing more than half of most
    /// subjects, and at 0.5 the notice fired on all ten test subjects after a
    /// 108 MB install: the notice-nobody-reads failure this constant exists to
    /// prevent.
    ///
    /// At four fifths, the reader holds under a fifth of what has been written
    /// on the subject they just asked about, and the answer they received was
    /// drawn from that fifth.
    static let missingShare = 0.8

    /// Which uninstalled packs would likely have helped with `question`.
    ///
    /// `queryTags` comes from the same tag extraction the retriever uses, so a
    /// suggestion is grounded in the question the retrieval actually ran.
    /// `installedFragments` is what is physically present. A collection counts
    /// as available when every fragment it needs is here, which is why this
    /// takes fragments rather than a list of collections the reader tapped:
    /// installing "Church Fathers" makes "Augustine of Hippo" available too, and
    /// suggesting it afterwards would be nonsense.
    public func suggest(question: String, queryTags: [String], installedFragments: Set<String>) -> [PackSuggestion] {
        var suggestions: [PackSuggestion] = []

        func available(_ c: PackContents) -> Bool {
            !c.fragments.isEmpty && c.fragments.allSatisfy(installedFragments.contains)
        }

        let missingFragments = fragments.keys.filter { !installedFragments.contains($0) }

        // Whose writing is already on the device. Without this, a question about
        // Augustine kept prompting to install him *after he had been installed*,
        // because the Catholic collection also lists him and that collection was
        // still incomplete. Being told to add what you already have is the
        // fastest way to teach someone to ignore a notice.
        var haveAuthors = Set<String>()
        var haveTitles = Set<String>()
        var haveTraditions = Set<String>()
        for id in installedFragments {
            guard let contents = fragments[id] else { continue }
            haveAuthors.formUnion(contents.authors)
            haveTitles.formUnion(contents.titles)
            haveTraditions.formUnion(contents.traditions)
        }

        // Which traditions the reader asked about and has nothing from. Computed
        // once, because it depends on the question and the device, not on the
        // pack being considered.
        let absentTraditions = Self.traditionsNamed(in: question).subtracting(haveTraditions)

        for (packID, contents) in orderedPacks {
            if available(contents) { continue }

            let author = contents.authors.first { author in
                !haveAuthors.contains(author)
                    && Self.nameParts(of: author).contains { Self.mentions(question, $0) }
            }
            if let author {
                suggestions.append(PackSuggestion(packID: packID, reason: .namesAuthor, detail: author))
                continue
            }

            let title = contents.titles.first { !haveTitles.contains($0) && Self.namesWork(question, $0) }
            if let title {
                suggestions.append(PackSuggestion(packID: packID, reason: .namesWork, detail: title))
                continue
            }

            // A tradition the reader asked about and holds nothing from. Checked
            // before subject coverage, and without any threshold: there is no
            // "enough" here, because the tradition is simply not on the device.
            if let tradition = contents.traditions.first(where: absentTraditions.contains) {
                suggestions.append(PackSuggestion(packID: packID, reason: .traditionAbsent, detail: tradition))
                continue
            }

            // Falling back to subject coverage. Deliberately last and
            // deliberately strict: a notice on every question is a notice nobody
            // reads.
            //
            // Only the pack holding the most of a subject is named, even when
            // several are missing — three notices for one question is nagging,
            // and the largest is the one worth installing first.
            for tag in queryTags {
                let everywhere = total(for: tag)
                if everywhere == 0 { continue }

                // Summed over fragments, each of which holds its text once.
                let absent = missingFragments.reduce(0) { $0 + (fragments[$1]?.tags[tag] ?? 0) }
                if Double(absent) / Double(everywhere) < Self.missingShare { continue }

                // Named on the collection that would close most of the gap, so
                // the suggestion is worth acting on rather than technically
                // correct. On a tie the earlier pack in the catalogue wins, as
                // Dart's `reduce` with `>=` keeps it.
                var best: (id: String, contents: PackContents)?
                for candidate in orderedPacks where !available(candidate.contents) {
                    if let current = best, (current.contents.tags[tag] ?? 0) >= (candidate.contents.tags[tag] ?? 0) {
                        continue
                    }
                    best = candidate
                }
                if best?.id != packID { continue }

                suggestions.append(PackSuggestion(
                    packID: packID,
                    reason: .coversSubject,
                    detail: tag.replacingOccurrences(of: "-", with: " ")
                ))
                break
            }
        }

        // Collections overlap by design, so one question routinely matches
        // several: asking about Chrysostom matches "John Chrysostom", "Nicene &
        // Post-Nicene Writers" and "Church Fathers", all of which would answer
        // it. Offering three is worse than offering one.
        //
        // The narrowest wins — measured by how many works it holds — because it
        // is the cheapest way to get an answer, and anyone wanting more can take
        // a broader collection afterwards. Suggesting the largest would be
        // asking someone to download the complete fathers to read one letter.
        // ...except when the reason is that a whole tradition is missing, where
        // narrowest is the wrong answer and so is broadest.
        //
        // Once per-author collections existed, "What do Baptists believe about
        // baptism?" started offering *John Bunyan* — two works, and Baptist, so
        // both the filter and the narrowness rule were satisfied. But the gap
        // being reported is not "you lack a Baptist author", it is "you lack the
        // Baptist tradition", and Bunyan's allegories are not the Baptist
        // confessions. Inverting to breadth alone overshoots the other way, to
        // "Creeds & Confessions" — which does hold Baptist material, among six
        // other traditions, and is not what was asked about either.
        //
        // What actually distinguishes the right answer is that the collection is
        // *about* that tradition and nothing else. So: collections covering one
        // tradition first, and the fullest of those, which is the one that
        // genuinely supplies what is missing.
        //
        // Swift's sort is stable; Dart's is stable for lists of up to 32 (an
        // insertion sort) and not beyond. Suggestions are one per pack at most,
        // and far fewer in practice, so ties keep catalogue order in both.
        suggestions.sort { a, b in compare(a, b) < 0 }

        var seen = Set<String>()
        return suggestions.filter { seen.insert("\($0.reason.rawValue)|\($0.detail)").inserted }
    }

    private func compare(_ a: PackSuggestion, _ b: PackSuggestion) -> Int {
        if a.reason != b.reason { return a.reason.rawValue - b.reason.rawValue }
        if a.reason == .traditionAbsent {
            let byFocus = traditionCount(a.packID) - traditionCount(b.packID)
            if byFocus != 0 { return byFocus }
            return worksCount(b.packID) - worksCount(a.packID)
        }
        return worksCount(a.packID) - worksCount(b.packID)
    }

    private func worksCount(_ packID: String) -> Int { packs[packID]?.titles.count ?? 0 }

    /// How many traditions a collection spans. One means it is *about* a
    /// tradition rather than merely containing some of it.
    private func traditionCount(_ packID: String) -> Int { packs[packID]?.traditions.count ?? 1 << 20 }

    /// How many tagged passages exist for `tag` across the whole library,
    /// installed or not.
    private func total(for tag: String) -> Int {
        (core[tag] ?? 0) + fragments.values.reduce(0) { $0 + ($1.tags[tag] ?? 0) }
    }

    /// "Augustine of Hippo" should be found by "Augustine", and "John
    /// Chrysostom" by "Chrysostom" — but not by "John", which would match any
    /// question mentioning the gospel.
    static func nameParts(of author: String) -> [String] {
        let tooCommon: Set<String> = ["john", "gregory", "clement", "the", "of", "saint"]
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            let part = String(current)
            if part.utf16.count > 3 && !tooCommon.contains(part.lowercased()) { parts.append(part) }
            current = String.UnicodeScalarView()
        }
        // `split(RegExp(r'[\s/]+'))`, with JavaScript's `\s`.
        for scalar in author.unicodeScalars {
            if scalar == "/" || isJavaScriptWhitespace(scalar) { flush() } else { current.append(scalar) }
        }
        flush()
        return [author] + parts
    }

    private static func isJavaScriptWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    // MARK: - Strict JSON reads, as Dart's casts are

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    static func formatError(_ what: String) -> FormatError {
        FormatError(description: "Malformed pack catalogue: \(what)")
    }

    static func string(_ json: OrderedJSON) throws -> String {
        switch json {
        case .string(let s): return s
        // `as String?` with a default: null reads as absent.
        case .null: return ""
        default: throw formatError("expected a string")
        }
    }

    static func strings(_ json: OrderedJSON) throws -> [String] {
        switch json {
        case .null: return []
        case .array(let items):
            return try items.map {
                guard case .string(let s) = $0 else { throw formatError("expected a list of strings") }
                return s
            }
        default: throw formatError("expected a list")
        }
    }

    static func counts(_ json: OrderedJSON) throws -> [String: Int] {
        switch json {
        case .null: return [:]
        case .object(let members):
            var out: [String: Int] = [:]
            for (key, value) in members {
                guard case .int(let n) = value else { throw formatError("expected a whole-number count") }
                out[key] = n
            }
            return out
        default: throw formatError("expected an object of counts")
        }
    }
}

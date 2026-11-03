// Port of lib/src/services/search/entity_recogniser.dart.
//
// Golden stage: `entities` in shared/golden/search/search.json.

import GRDB

/// What a question named, resolved to rows in the database.
public struct RecognisedEntities: Sendable, Equatable {
    /// Source ids, in the order the recogniser added them (authors' works
    /// first, then named works). Dart keeps these in an insertion-ordered set,
    /// and callers that iterate them inherit the order.
    public let sourceIds: [Int]

    /// Tradition ids in the order recognised: whole names first (by ascending
    /// id), then single words in the order the question used them.
    /// `_ensureNamedTraditions` walks them in this order.
    public let traditionIds: [Int]

    /// Human-readable names of what matched, for showing the user what the app
    /// understood — a scoped search that silently narrows is worse than one
    /// that says "searching within Aquinas".
    public let labels: [String]

    public init(sourceIds: [Int] = [], traditionIds: [Int] = [], labels: [String] = []) {
        self.sourceIds = sourceIds
        self.traditionIds = traditionIds
        self.labels = labels
    }

    public static let none = RecognisedEntities()

    public var isEmpty: Bool { sourceIds.isEmpty && traditionIds.isEmpty }
}

/// Recognises authors, works and traditions named in a question.
///
/// Retrieval scores passages on text similarity alone, so a question like
/// "what did Aquinas say about Mary?" treats "Aquinas" as one more word to
/// match rather than as a constraint. The result is passages about Mary from
/// whoever wrote most about her — and, in one observed case, a hit on "the
/// most blessed Thomas", meaning the apostle.
///
/// Matching is on metadata rather than body text, which also disambiguates the
/// opposite failure: "Catholic" in a question means the modern communion,
/// while "Catholic" in Augustine means the universal church against the
/// Donatists. Matching the tradition row cannot confuse the two.
public struct EntityRecogniser: Sendable {
    /// A `sources` row as the recogniser reads it.
    public struct SourceRow: Sendable {
        public let id: Int
        public let title: String?
        public let author: String?

        public init(id: Int, title: String?, author: String?) {
            self.id = id
            self.title = title
            self.author = author
        }
    }

    /// A `traditions` row as the recogniser reads it.
    public struct TraditionRow: Sendable {
        public let id: Int
        public let name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Words too common to identify anything on their own.
    static let stopwords: Set<String> = [
        "the", "of", "and", "on", "in", "to", "a", "an", "for", "from", "by",
        "with", "against", "concerning", "book", "books", "part", "volume", "vol",
        "saint", "st", "selections", "fragments", "epistle", "epistles", "letter",
        "letters", "homily", "homilies", "treatise", "works", "church", "holy",
        "christian", "god", "first", "second", "third", "new", "old",
        // The persons of the Trinity, and the names for Christ. These are rare
        // in *titles* and ubiquitous in *questions*, which is the combination
        // the rarity rule below cannot survive: "Is the Son equal to the
        // Father?" supplied two tokens rare enough to look distinctive and
        // scoped the whole question to Owen's *Of Communion with God the
        // Father, Son and Holy Ghost*. That is the "saved"/"virgin"/"topics"
        // failure again — a word can be rare among titles and still identify
        // nothing — arriving through two rare words at once rather than one.
        "father", "son", "spirit", "ghost", "lord", "jesus", "christ",
    ]

    /// How much of a work's title a question must use before it counts as
    /// naming that work.
    ///
    /// A single rare token is deliberately *not* enough. Tokens like "virgin",
    /// "topics" and "saved" appear in only one or two titles while being
    /// ordinary vocabulary, so treating rarity as identity scoped "how is a
    /// person saved?" to *Who is the Rich Man That Shall Be Saved?* and a
    /// question about the Virgin Mary to *Apocalypse of the Virgin*. Requiring
    /// two matching tokens costs the ability to resolve a bare surname and buys
    /// freedom from that whole class of false positive.
    static let minTokensNamingWork = 2
    static let minTitleFraction = 0.6

    /// A token appearing in at most this many works is distinctive enough that
    /// matching it, *alongside at least one other token*, names the work even
    /// if the title is long.
    ///
    /// Without this, renaming "Council of Trent" to "The Canons and Decrees of
    /// the Council of Trent" silently broke scoping: the question supplies
    /// "council" and "trent", which is two of four title tokens and falls under
    /// the fraction. Requiring two tokens still holds, so this does not reopen
    /// the single-rare-token false positives ("saved", "virgin", "topics").
    static let distinctiveWorkThreshold = 2

    /// A question naming more works than this is naming a topic, not a work.
    static let maxNamedWorks = 6

    /// Token -> the sources whose title or author contains it, ascending id.
    private let sourceTokens: [String: OrderedSet<Int>]
    private let sourceNames: [Int: String]
    private let sourceTokenCounts: [Int: Int]
    private let traditionTokens: [String: Int]
    private let traditionNames: [Int: String]

    /// Traditions whose names tokenise to more than one word, by ascending id,
    /// so a question that spells one out in full is matched to it rather than
    /// word by word.
    private let traditionPhrases: [(id: Int, words: Set<String>)]

    /// Distinctive token -> author name. Authors are a separate axis from works
    /// because they scope differently: Augustine names 45 works, which is a
    /// meaningful constraint even though no single work is meant.
    private let authorTokens: [String: String]
    /// Keyed by code units, as the Dart map is: two spellings of one name
    /// that differ only in normalisation are two authors there.
    private let authorSources: [ExactString: OrderedSet<Int>]

    /// `[a-z0-9']` runs of the Dart-lowercased text, longer than two
    /// characters and not stopwords, in order and with repeats.
    static func tokenise(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            // Only ASCII survives, so the scalar count is Dart's length.
            if current.count > 2 {
                let token = String(current)
                if !stopwords.contains(token) { tokens.append(token) }
            }
            current = String.UnicodeScalarView()
        }
        for scalar in DartText.lowercased(text).unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39, 0x27: current.append(scalar)
            default: flush()
            }
        }
        flush()
        return tokens
    }

    /// Load from the corpus.
    ///
    /// Ordered, so nothing below depends on the query plan. Unordered, SQLite
    /// answers the traditions query from the UNIQUE index on `name`, and the
    /// order of work labels follows the order sources are read in.
    public static func load(from db: Database) throws -> EntityRecogniser {
        let sources = try Row.fetchAll(db, sql: "SELECT id, title, author FROM sources ORDER BY id")
            .map { SourceRow(id: $0["id"], title: $0["title"], author: $0["author"]) }
        let traditions = try Row.fetchAll(db, sql: "SELECT id, name FROM traditions ORDER BY id")
            .map { TraditionRow(id: $0["id"], name: $0["name"]) }
        return EntityRecogniser(sources: sources, traditions: traditions)
    }

    /// Build from plain rows, so the matching rules can be tested against
    /// fixtures without a database. Pass them in ascending id, as `load` does.
    public init(sources: [SourceRow], traditions: [TraditionRow]) {
        var sourceTokens: [String: OrderedSet<Int>] = [:]
        var sourceNames: [Int: String] = [:]
        var sourceTokenCounts: [Int: Int] = [:]

        for row in sources {
            sourceNames[row.id] = row.title ?? ""
            var tokens = OrderedSet(Self.tokenise(row.title ?? ""))
            tokens.insert(contentsOf: Self.tokenise(row.author ?? ""))
            sourceTokenCounts[row.id] = tokens.count
            for token in tokens {
                sourceTokens[token, default: OrderedSet()].insert(row.id)
            }
        }

        // Author index, keyed on tokens distinctive among authors rather than
        // among works: "john" names three authors and identifies none of them,
        // while "chrysostom" names exactly one.
        var authorSources: [ExactString: OrderedSet<Int>] = [:]
        var authorOrder: [String] = []
        for row in sources {
            let author = DartText.trimmed(row.author ?? "")
            if author.isEmpty || DartText.equal(author, "Miscellaneous") || DartText.equal(author, "Apocrypha") {
                continue
            }
            let key = ExactString(author)
            if authorSources[key] == nil { authorOrder.append(author) }
            authorSources[key, default: OrderedSet()].insert(row.id)
        }

        var tokenAuthors: [String: Set<ExactString>] = [:]
        for author in authorOrder {
            for token in Self.tokenise(author) {
                tokenAuthors[token, default: []].insert(ExactString(author))
            }
        }
        var authorTokens: [String: String] = [:]
        for (token, authors) in tokenAuthors where authors.count == 1 {
            authorTokens[token] = authors.first!.value
        }

        var traditionNames: [Int: String] = [:]
        for row in traditions {
            traditionNames[row.id] = row.name
        }

        // A word several traditions share goes to the one with the fewest
        // words in its name, then the shortest name, then the lowest id.
        // "Catholic" is in five names, and the reader who types it means
        // Catholic, not Polish National Catholic. This used to be
        // last-write-wins over the row order, which SQLite took from the name
        // index, so "catholic" went to Polish National Catholic and "orthodox"
        // to Oriental Orthodox. The rule is a total order, so the result does
        // not depend on row order.
        func beats(_ id: Int, _ other: Int) -> Bool {
            let a = traditionNames[id]!, b = traditionNames[other]!
            // `split(' ').length`: one more than the number of spaces.
            let aWords = a.utf16.count(where: { $0 == 0x20 })
            let bWords = b.utf16.count(where: { $0 == 0x20 })
            if aWords != bWords { return aWords < bWords }
            // Dart's `length` is UTF-16 code units.
            let aLength = a.utf16.count, bLength = b.utf16.count
            if aLength != bLength { return aLength < bLength }
            return id < other
        }

        var traditionTokens: [String: Int] = [:]
        func claim(_ token: String, _ id: Int) {
            if let held = traditionTokens[token], !beats(id, held) { return }
            traditionTokens[token] = id
        }

        for row in traditions {
            for token in Self.tokenise(row.name) {
                claim(token, row.id)
            }
            // Traditions are named in questions adjectivally far more often
            // than by their row name: "what do Lutherans believe", not
            // "Lutheran tradition".
            for form in Self.adjectivalForms(row.name) {
                claim(form, row.id)
            }
        }

        var traditionPhrases: [(id: Int, words: Set<String>)] = []
        for id in traditionNames.keys.sorted() {
            let words = Set(Self.tokenise(traditionNames[id]!))
            if words.count > 1 { traditionPhrases.append((id, words)) }
        }

        self.sourceTokens = sourceTokens
        self.sourceNames = sourceNames
        self.sourceTokenCounts = sourceTokenCounts
        self.traditionTokens = traditionTokens
        self.traditionNames = traditionNames
        self.traditionPhrases = traditionPhrases
        self.authorTokens = authorTokens
        self.authorSources = authorSources
    }

    /// The forms a tradition is named by in a question: the last word of its
    /// name, lowercased but not tokenised, and its plurals and synonyms.
    static func adjectivalForms(_ name: String) -> [String] {
        let lower = DartText.lowercased(name)
        // `split(' ').last`: everything after the last space.
        let base: String
        if let space = lower.unicodeScalars.lastIndex(of: " ") {
            base = String(lower.unicodeScalars[lower.unicodeScalars.index(after: space)...])
        } else {
            base = lower
        }
        var forms = [base, base + "s"]
        if base.utf16.reversed().starts(with: "an".utf16.reversed()) { forms.append(base + "s") }
        if DartText.equal(base, "orthodoxy") { forms.append("orthodox") }
        if DartText.equal(base, "reformed") { forms.append("calvinist") }
        if DartText.equal(base, "catholic") { forms.append("roman") }
        return forms
    }

    /// Resolve whatever `query` names. Returns empty when it names nothing,
    /// which is the common case and must stay cheap.
    public func recognise(_ query: String) -> RecognisedEntities {
        let tokens = OrderedSet(Self.tokenise(query))
        if tokens.isEmpty { return .none }
        let tokenSet = Set(tokens.elements)

        var traditionIds = OrderedSet<Int>()
        var labels: [String] = []

        // A name given in full wins its words: "Eastern Catholic" is one
        // tradition, not Eastern Orthodox plus Catholic.
        var unclaimed = tokens
        for (id, words) in traditionPhrases where words.isSubset(of: tokenSet) {
            unclaimed.remove(contentsOf: words)
            if traditionIds.insert(id) { labels.append(traditionNames[id]!) }
        }

        for token in unclaimed {
            if let id = traditionTokens[token], traditionIds.insert(id) {
                labels.append(traditionNames[id]!)
            }
        }

        // Authors first: naming one scopes to everything they wrote.
        var sourceIds = OrderedSet<Int>()
        for token in tokens {
            if let author = authorTokens[token], !labels.contains(where: { DartText.equal($0, author) }) {
                sourceIds.insert(contentsOf: authorSources[ExactString(author)]!)
                labels.append(author)
            }
        }
        let namedAuthor = !sourceIds.isEmpty

        // Then individual works. Score each candidate by how much of its
        // identity the question used, so "On the Trinity" does not match every
        // work with "trinity" in the title — except where a token is rare
        // enough to identify its work by itself.
        var hitOrder: [Int] = []
        var hits: [Int: Int] = [:]
        var withDistinctive = Set<Int>()
        for token in tokens {
            guard let candidates = sourceTokens[token] else { continue }
            if candidates.count <= Self.distinctiveWorkThreshold {
                withDistinctive.formUnion(candidates.elements)
            }
            for id in candidates {
                if let count = hits[id] {
                    hits[id] = count + 1
                } else {
                    hits[id] = 1
                    hitOrder.append(id)
                }
            }
        }

        var namedWorks = OrderedSet<Int>()
        for id in hitOrder {
            let count = hits[id]!
            let total = sourceTokenCounts[id] ?? 0
            if total == 0 || count < Self.minTokensNamingWork { continue }
            if count >= total
                || Double(count) >= Double(total) * Self.minTitleFraction
                || withDistinctive.contains(id) {
                namedWorks.insert(id)
            }
        }

        // Naming many works at once is naming a topic. An author scope is
        // exempt: it legitimately covers dozens of works.
        if namedWorks.count > Self.maxNamedWorks {
            return RecognisedEntities(
                sourceIds: namedAuthor ? sourceIds.elements : [],
                traditionIds: traditionIds.elements,
                labels: labels
            )
        }

        for id in namedWorks {
            sourceIds.insert(id)
            labels.append(sourceNames[id]!)
        }

        return RecognisedEntities(
            sourceIds: sourceIds.elements,
            traditionIds: traditionIds.elements,
            labels: labels
        )
    }
}

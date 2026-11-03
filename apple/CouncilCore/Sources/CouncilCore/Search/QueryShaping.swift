// Port of the pure query-shaping helpers in
// lib/src/services/database_service.dart: `ftsMatchQuery` (with
// `_prefixTerm`), `escapeLike`, `extractTags` and `tagSlugs`. The SQL that
// uses them lives with retrieval.
//
// Golden stages: `ftsMatch` and `tags` in shared/golden/search/search.json.

/// Turns a reader's question into the strings retrieval queries with.
public enum QueryShaping {
    // MARK: - FTS5

    /// Words dropped from the FTS5 expression.
    ///
    /// Terms are joined with OR, not AND: requiring every word of a
    /// conversational question — "did", "the" included — to appear in a single
    /// passage matched **zero** units for "What did the Council of Trent decree
    /// about justification?", where the OR form matches 1,423. Ranking already
    /// rewards passages containing more of the rarer terms, so OR gives up
    /// nothing in precision. Short words are dropped for the same reason.
    ///
    /// Stopwords are dropped because of what the `*` costs. Every term is a
    /// prefix match, and `the*` matches most of the index — so a question
    /// phrased as a sentence asked FTS5 to rank a large fraction of the corpus
    /// in order to return six passages. That was survivable at 123 M characters
    /// and stopped being survivable at 453 M: a scoped question — where the
    /// filter admits one source in 638, so the scan runs a long way down the
    /// ranking before finding anything — went from about a second to over
    /// thirty. Dropping them costs nothing in precision, since a passage was
    /// never going to be worth returning because it contains "about".
    static let ftsStopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "has", "had", "have", "was", "were", "what", "when", "where", "which",
        "who", "whom", "why", "how", "did", "does", "about", "from", "into",
        "that", "this", "these", "those", "with", "without", "they", "them",
        "their", "there", "then", "than", "his", "her", "its", "our", "your",
        "say", "said", "says", "tell", "teach", "believe", "mean", "means",
        "between", "differences", "difference",
    ]

    /// The FTS5 MATCH expression for `query`: its words, as typed, each as a
    /// quoted prefix term, joined with OR. Empty when nothing survives, which
    /// means no FTS query is run.
    ///
    /// Letters and digits in any script survive; everything else separates.
    /// `\w` cannot do this job — Dart's is ASCII-only, so it deleted the
    /// letters of exactly the words this corpus is most particular about.
    /// "Küng" came out as "K ng" and then vanished under the length filter,
    /// leaving an empty match and a full-corpus LIKE scan behind it; "Grégoire"
    /// came out as "goire"; "Νίκαια" and "ὁμοούσιος" disappeared entirely.
    /// FTS5 itself was never the problem: its unicode61 tokenizer indexes
    /// Greek happily and folds diacritics, so "gregoire" finds Grégoire once
    /// the letters actually reach it.
    ///
    /// A combining mark (`\p{M}`) is a separator, not a letter, so decomposed
    /// "Nicée" becomes `"Nice"*` — while the tokenizer strips the mark and
    /// folds the word to `nicee`. Lengths are UTF-16 code units, as Dart's are.
    public static func ftsMatchQuery(_ query: String) -> String {
        ftsTerms(query).map(prefixTerm).joined(separator: " OR ")
    }

    /// The words `ftsMatchQuery` searches for, unquoted: what the reader's
    /// query reaches FTS5 as, each matched as a prefix. The search screen
    /// marks them in the passages it found (`SearchHits`).
    public static func ftsTerms(_ query: String) -> [String] {
        // `replaceAll(RegExp(r'[^\p{L}\p{N}_\s]', unicode: true), ' ')`
        var cleaned = String.UnicodeScalarView()
        for scalar in query.unicodeScalars {
            cleaned.append(keepsInFTS(scalar) ? scalar : " ")
        }

        // `split(RegExp(r'\s+'))`, then `where((t) => t.length > 2)`.
        var words: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            let word = String(current)
            if word.utf16.count > 2 { words.append(word) }
            current = String.UnicodeScalarView()
        }
        for scalar in cleaned {
            if DartText.isRegExpWhitespace(scalar) { flush() } else { current.append(scalar) }
        }
        flush()

        var terms = words.filter { !ftsStopwords.contains(DartText.lowercased($0)) }

        // A question made entirely of stopwords ("what are these about?") would
        // otherwise match nothing at all, which is worse than matching too
        // much.
        if terms.isEmpty { terms = words }
        return terms
    }

    private static func keepsInFTS(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || DartText.isRegExpWhitespace(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// One FTS5 prefix term, quoted.
    ///
    /// The quoting is not decoration. A bareword that happens to spell an FTS5
    /// operator is parsed as one, and the stopword fallback hands back the
    /// reader's words *as typed* — so "WHY NOT", two stopwords in either case,
    /// became `WHY* OR NOT*`, which is a syntax error rather than a search.
    /// In the Flutter Read tab, whose search had no catch, it left the spinner
    /// turning for good.
    ///
    /// Inside a quoted string FTS5 reads those words as text. A literal quote
    /// is written by doubling it.
    static func prefixTerm(_ word: String) -> String {
        "\"" + word.replacing("\"", with: "\"\"") + "\"*"
    }

    // MARK: - LIKE

    /// Escape the two characters LIKE reads as wildcards, for use with
    /// `LIKE ? ESCAPE '\'`.
    ///
    /// Searching for "100%" otherwise asks for the whole library: `%100%%`
    /// matches every unit there is, and forty arbitrary passages come back
    /// looking like results. `_` is the single-character wildcard and does the
    /// same in miniature — a reader searching `__init__` or a bare `_` got the
    /// same thing.
    public static func escapeLike(_ value: String) -> String {
        // By scalar rather than with `replacing`, which matches Characters:
        // a backslash followed by a combining mark is one Character and would
        // be missed.
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "%": out.append(contentsOf: "\\%".unicodeScalars)
            case "_": out.append(contentsOf: "\\_".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Tags

    /// The complete tag vocabulary present in the bundled database.
    ///
    /// Every slug produced by `extractTags` must appear here — a mapping to a
    /// slug outside this set matches nothing and silently degrades retrieval.
    public static let tagSlugs: Set<String> = [
        "angels", "baptism", "christology", "church", "creation", "eschatology",
        "eucharist", "faith", "grace", "holy-spirit", "incarnation",
        "justification", "last-judgment", "prayer", "sacraments", "salvation",
        "sanctification", "scripture", "sin", "trinity", "worship",
    ]

    /// Query phrases mapped onto the tag vocabulary, in the Dart map's order,
    /// which is the order slugs are reported in.
    ///
    /// Several phrases are technical names for a doctrine the database tags
    /// under a plainer slug (soteriology → salvation, ecclesiology → church),
    /// so the mapping is many-to-many rather than one-to-one.
    static let tagSynonyms: [(phrase: String, slugs: [String])] = [
        ("angel", ["angels"]),
        ("atonement", ["salvation", "christology"]),
        ("baptism", ["baptism"]),
        ("christology", ["christology"]),
        ("church", ["church"]),
        ("communion", ["eucharist", "sacraments"]),
        ("creation", ["creation"]),
        ("ecclesiology", ["church"]),
        ("eschatology", ["eschatology"]),
        ("eucharist", ["eucharist"]),
        ("faith", ["faith"]),
        ("free will", ["grace", "salvation"]),
        ("grace", ["grace"]),
        ("heaven", ["eschatology"]),
        ("hell", ["eschatology", "last-judgment"]),
        ("holiness", ["sanctification"]),
        ("holy spirit", ["holy-spirit"]),
        ("incarnation", ["incarnation"]),
        ("judgment", ["last-judgment"]),
        ("justification", ["justification"]),
        ("liturgy", ["worship"]),
        ("lord's supper", ["eucharist", "sacraments"]),
        ("mass", ["eucharist"]),
        ("pneumatology", ["holy-spirit"]),
        ("prayer", ["prayer"]),
        ("predestination", ["salvation", "grace"]),
        ("resurrection", ["eschatology", "christology"]),
        ("sacrament", ["sacraments"]),
        ("salvation", ["salvation"]),
        ("sanctification", ["sanctification"]),
        ("scripture", ["scripture"]),
        ("second coming", ["eschatology"]),
        ("sin", ["sin"]),
        ("soteriology", ["salvation"]),
        ("trinity", ["trinity"]),
        ("worship", ["worship"]),
    ]

    /// Extract tag slugs from a query, deduplicated, in the order first
    /// produced.
    ///
    /// Plain substring matching produces nonsense hits — "hello" contains
    /// "hell", "sincere" contains "sin", "evangelical" contains "angel" — so
    /// each phrase is anchored on word boundaries, with an optional plural
    /// suffix so "sins" and "sacraments" still match.
    ///
    /// The Dart code does this with `RegExp(r'\b<phrase>(s|es)?\b',
    /// caseSensitive: false)`, a non-Unicode ECMAScript pattern. That makes
    /// both `\b` and case-insensitivity ASCII-only: "é" is not a word
    /// character, so "siné" contains "sin", and no non-ASCII letter matches an
    /// ASCII one. NSRegularExpression and Swift Regex use Unicode word
    /// boundaries, so the match is done by hand over UTF-16 code units.
    ///
    /// The coverage notice needs the same reading of the question that
    /// retrieval used, so it should call this rather than derive the subject a
    /// second way.
    public static func extractTags(_ query: String) -> [String] {
        let units = Array(query.utf16)
        var matched = OrderedSet<String>()
        for (phrase, slugs) in tagSynonyms where containsWord(phrase, in: units) {
            matched.insert(contentsOf: slugs)
        }
        return matched.elements
    }

    private static let pluralSuffixes: [[UInt16]] = [Array("s".utf16), Array("es".utf16), []]

    /// Whether `\b<phrase>(s|es)?\b` matches anywhere in `units`,
    /// case-insensitively in ASCII.
    static func containsWord(_ phrase: String, in units: [UInt16]) -> Bool {
        let phrase = Array(phrase.utf16)
        func isWord(_ at: Int) -> Bool {
            guard at >= 0 && at < units.count else { return false }
            let unit = units[at]
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
        }
        func isBoundary(_ at: Int) -> Bool { isWord(at - 1) != isWord(at) }
        func foldedASCII(_ unit: UInt16) -> UInt16 {
            unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
        }
        func matches(_ literal: [UInt16], at start: Int) -> Bool {
            guard start + literal.count <= units.count else { return false }
            for (offset, unit) in literal.enumerated()
            where foldedASCII(units[start + offset]) != foldedASCII(unit) {
                return false
            }
            return true
        }

        guard units.count >= phrase.count else { return false }
        for start in 0...(units.count - phrase.count) {
            guard isBoundary(start), matches(phrase, at: start) else { continue }
            let afterPhrase = start + phrase.count
            // `(s|es)?` tries "s", then "es", then nothing, backtracking into
            // the next alternative when the closing `\b` fails.
            for suffix in pluralSuffixes where matches(suffix, at: afterPhrase) {
                if isBoundary(afterPhrase + suffix.count) { return true }
            }
        }
        return false
    }
}

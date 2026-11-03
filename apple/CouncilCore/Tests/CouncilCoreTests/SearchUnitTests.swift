import Foundation
import Testing
@testable import CouncilCore

// Ports of the Flutter unit tests for the search building blocks
// (test/wordpiece_tokenizer_test.dart, test/entity_recogniser_test.dart,
// test/search_query_test.dart, test/database_service_test.dart,
// test/hybrid_ranker_test.dart), for the behaviour the golden fixture does
// not reach: the core corpus has one source, so authors and works are never
// recognised there.

@Suite("WordPiece tokenizer")
struct WordPieceTokenizerTests {
    let tokenizer = SearchGoldenTests.tokenizer

    /// The output of `tokenizers.Tokenizer.from_file(tokenizer.json)`.
    @Test(arguments: [
        ("How is a person saved?", [101, 2129, 2003, 1037, 2711, 5552, 1029, 102]),
        ("the Nicene Creed, A.D. 325",
         [101, 1996, 3835, 2638, 16438, 1010, 1037, 1012, 1040, 1012, 19652, 102]),
        ("Chrysostom's homilies on Matthew",
         [101, 10381, 24769, 14122, 5358, 1005, 1055, 7570, 4328, 11983, 2006, 5487, 102]),
        ("transubstantiation", [101, 9099, 12083, 12693, 10711, 3508, 102]),
        ("ὁμοούσιος", [101, 1169, 29728, 29730, 26789, 29733, 18199, 15297, 102]),
        ("Νίκαια", [101, 1167, 18199, 29726, 14608, 27432, 102]),
        ("Grégoire de Nazianze", [101, 6754, 26250, 2139, 6394, 2319, 4371, 102]),
        ("Gre\u{0301}goire de Nazianze", [101, 6754, 26250, 2139, 6394, 2319, 4371, 102]),
        ("Küng", [101, 18577, 102]),
        ("façade", [101, 8508, 102]),
        ("", [101, 102]),
    ])
    func matchesThePythonTokenizer(_ text: String, _ expected: [Int]) {
        #expect(tokenizer.encode(text) == expected)
    }

    @Test func accentedWordsAreNeverUnknown() {
        for word in ["ὁμοούσιος", "Νίκαια", "Grégoire", "Küng", "façade", "Ἰησοῦς", "θεολογία"] {
            #expect(!tokenizer.encode(word).contains(100), "\(word) encoded to [UNK]")
        }
    }

    @Test func truncatesKeepingSeparator() {
        let ids = tokenizer.encode(String(repeating: "word ", count: 1000))
        #expect(ids.count == WordPieceTokenizer.maxTokens)
        #expect(ids.first == 101)
        #expect(ids.last == 102)
    }

    @Test func overlongWordIsOneUnknown() {
        #expect(tokenizer.encode(String(repeating: "a", count: 101)) == [101, 100, 102])
    }

    @Test func crlfVocabularyLinesAreTrimmed() throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: "[PAD]\r\n[UNK]\r\n[CLS]\r\n[SEP]\r\nhi\r\n")
        #expect(tokenizer.encode("hi") == [2, 4, 3])
    }

    @Test func missingSpecialTokenIsAnError() {
        #expect(throws: WordPieceTokenizer.LoadError.missingSpecialToken("[UNK]")) {
            try WordPieceTokenizer(vocabulary: "[CLS]\n[SEP]\n")
        }
    }
}

@Suite("Dart string semantics")
struct DartTextTests {
    @Test func lowercasesCodePointToCodePoint() {
        // Swift's full mapping makes "İ" two scalars; the Dart VM makes it "i".
        #expect(Array(DartText.lowercased("İstanbul").unicodeScalars) == Array("istanbul".unicodeScalars))
        #expect(EntityRecogniser.tokenise("İstanbul") == ["istanbul"])
    }
}

@Suite("Entity recogniser")
struct EntityRecogniserTests {
    /// Fixtures mirroring the shape of the real corpus: an author with many
    /// works, multi-word confession titles, and titles whose words are also
    /// ordinary theological vocabulary.
    static let recogniser = EntityRecogniser(
        sources: (1...6).map {
            .init(id: $0, title: "On the Trinity, Book \($0)", author: "Augustine of Hippo")
        } + [
            .init(id: 10, title: "Council of Trent", author: nil),
            .init(id: 11, title: "The Heidelberg Catechism", author: nil),
            .init(id: 12, title: "The Belgic Confession", author: nil),
            .init(id: 13, title: "Homilies on Matthew", author: "John Chrysostom"),
            .init(id: 14, title: "Homilies on Acts", author: "John Chrysostom"),
            // A second John, so "John" alone genuinely disambiguates nothing.
            .init(id: 15, title: "Exposition of the Orthodox Faith", author: "John of Damascus"),
            // Titles built from ordinary vocabulary — the false-positive traps.
            .init(id: 20, title: "Who is the Rich Man That Shall Be Saved?", author: nil),
            .init(id: 21, title: "Apocalypse of the Virgin", author: nil),
            .init(id: 22, title: "Twelve Topics on the Faith", author: nil),
        ],
        traditions: [
            .init(id: 1, name: "Catholic"),
            .init(id: 2, name: "Lutheran"),
            .init(id: 3, name: "Reformed"),
            .init(id: 4, name: "Early Church"),
        ]
    )

    var recogniser: EntityRecogniser { Self.recogniser }

    @Test func traditionNamedAdjectivally() {
        let result = recogniser.recognise("What are the differences between Catholic and Lutheran beliefs?")
        #expect(result.traditionIds == [1, 2])
        #expect(result.labels == ["Catholic", "Lutheran"])
    }

    @Test func calvinistIsReformed() {
        #expect(recogniser.recognise("Calvinist predestination").traditionIds == [3])
    }

    @Test(arguments: [false, true])
    func sharedWordGoesToShortestNameWhateverTheRowOrder(reversed: Bool) {
        // SQLite once returned these alphabetically, and the last row to claim
        // a word kept it: "catholic" meant Polish National Catholic.
        let rows: [EntityRecogniser.TraditionRow] = [
            .init(id: 2, name: "Catholic"),
            .init(id: 3, name: "Eastern Orthodox"),
            .init(id: 4, name: "Oriental Orthodox"),
            .init(id: 18, name: "Eastern Catholic"),
            .init(id: 28, name: "Polish National Catholic"),
        ]
        let r = EntityRecogniser(sources: [], traditions: reversed ? rows.reversed() : rows)
        #expect(r.recognise("Catholic teaching").traditionIds == [2])
        #expect(r.recognise("Roman Catholics").traditionIds == [2])
        #expect(r.recognise("Eastern icons").traditionIds == [3])
        #expect(r.recognise("Orthodox icons").traditionIds == [3])
        // A name given in full is that tradition, not its words separately.
        #expect(r.recognise("Oriental Orthodox").traditionIds == [4])
        #expect(r.recognise("Eastern Catholic rites").traditionIds == [18])
        #expect(r.recognise("Polish National Catholic").traditionIds == [28])
    }

    @Test func authorScopesToEverythingTheyWrote() {
        let result = recogniser.recognise("What did Augustine say about grace?")
        #expect(result.sourceIds == [1, 2, 3, 4, 5, 6])
        #expect(result.labels == ["Augustine of Hippo"])
    }

    @Test func authorByDistinctiveSurname() {
        #expect(recogniser.recognise("What does Chrysostom say about wealth?").sourceIds == [13, 14])
    }

    @Test func sharedForenameScopesNothing() {
        #expect(recogniser.recognise("what did John teach").isEmpty)
    }

    @Test func workNamedInFull() {
        let result = recogniser.recognise("What topics were covered at the Council of Trent?")
        #expect(result.sourceIds.contains(10))
        #expect(result.labels.contains("Council of Trent"))
    }

    @Test func longTitleFromDistinctiveTokenPlusOneMore() {
        let long = EntityRecogniser(
            sources: [
                .init(id: 30, title: "The Canons and Decrees of the Council of Trent", author: nil),
                .init(id: 31, title: "Twelve Topics on the Faith", author: nil),
            ],
            traditions: []
        )
        #expect(long.recognise("What did the Council of Trent decree about justification?")
            .sourceIds.contains(30))
        // Still must not fire on one ordinary token.
        #expect(long.recognise("What topics matter most?").sourceIds.isEmpty)
    }

    @Test func multiWordConfessionTitles() {
        #expect(recogniser.recognise("the Heidelberg Catechism on the sacraments").sourceIds.contains(11))
        #expect(recogniser.recognise("what does the Belgic Confession say").sourceIds.contains(12))
    }

    @Test func topicalQuestionsDoNotScope() {
        #expect(recogniser.recognise("How is a person saved?").isEmpty)
        #expect(recogniser.recognise("What topics matter most?").isEmpty)
        #expect(!recogniser.recognise("What did Aquinas say about the Virgin Mary?").sourceIds.contains(21))
        // "Trinity" appears in six titles; the question is about the doctrine.
        #expect(recogniser.recognise("Explain the doctrine of the Trinity").sourceIds.isEmpty)
        #expect(recogniser.recognise("Is the Son equal to the Father?").isEmpty)
        #expect(recogniser.recognise("").isEmpty)
    }

    @Test func authorAndWorkLabelsInOrder() {
        // Author scope first, then each named work, even one already in scope.
        let result = recogniser.recognise("Augustine On the Trinity, Book 1")
        #expect(result.sourceIds == [1, 2, 3, 4, 5, 6])
        #expect(result.labels.first == "Augustine of Hippo")
    }
}

@Suite("Query shaping")
struct QueryShapingTests {
    @Test func stopwordOnlyQueryKeepsWordsAndQuotesThem() {
        // `WHY* OR NOT*` was an FTS5 syntax error.
        #expect(QueryShaping.ftsMatchQuery("WHY NOT") == "\"WHY\"* OR \"NOT\"*")
        #expect(QueryShaping.ftsMatchQuery("What of \"faith alone\" (sola)?")
            == "\"faith\"* OR \"alone\"* OR \"sola\"*")
    }

    @Test func keepsLettersFromAnyScript() {
        #expect(QueryShaping.ftsMatchQuery("Küng") == "\"Küng\"*")
        #expect(QueryShaping.ftsMatchQuery("Νίκαια") == "\"Νίκαια\"*")
        #expect(QueryShaping.ftsMatchQuery("") == "")
        #expect(QueryShaping.ftsMatchQuery("a of  ?") == "")
    }

    @Test func escapesLikeWildcards() {
        #expect(QueryShaping.escapeLike("100%") == #"100\%"#)
        #expect(QueryShaping.escapeLike("__init__") == #"\_\_init\_\_"#)
        #expect(QueryShaping.escapeLike(#"a\b"#) == #"a\\b"#)
    }

    @Test func tagsMatchWholeWordsOnly() {
        for query in ["hello there", "a sincere question", "evangelical theology",
                      "that was a massive council", "it fell into disgrace", "what should I read next"] {
            #expect(QueryShaping.extractTags(query).isEmpty, "\(query)")
        }
        #expect(QueryShaping.extractTags("our sins") == ["sin"])
        #expect(QueryShaping.extractTags("THE TRINITY") == ["trinity"])
        #expect(QueryShaping.extractTags("is communion the same as the eucharist") == ["eucharist", "sacraments"])
        #expect(QueryShaping.extractTags("what is soteriology") == ["salvation"])
        // ASCII word boundaries, as in a non-Unicode Dart RegExp: "é" is not
        // a word character.
        #expect(QueryShaping.extractTags("siné") == ["sin"])
    }

    @Test func everyMappedSlugIsInTheVocabulary() {
        for (_, slugs) in QueryShaping.tagSynonyms {
            #expect(slugs.allSatisfy(QueryShaping.tagSlugs.contains))
        }
    }
}

@Suite("Hybrid ranker")
struct HybridRankerTests {
    @Test func agreementPromotesAndDuplicatesCountOnce() {
        #expect(HybridRanker.fuse(lexical: [1, 2, 2], semantic: [2, 3]) == [2, 1, 3])
        // Exact ties break by ascending id.
        #expect(HybridRanker.fuse(lexical: [9], semantic: [4]) == [4, 9])
        #expect(HybridRanker.fuse(lexical: [1, 2, 3], semantic: [], limit: 2) == [1, 2])
    }

    struct Result: Equatable {
        let source: String
        let tradition: String
    }

    func diversify(_ input: [Result], limit: Int = 6) -> [Result] {
        HybridRanker.diversify(input, sourceOf: \.source, traditionOf: \.tradition, limit: limit)
    }

    @Test func letsMinorityTraditionThrough() {
        let ranked = (0..<10).map { Result(source: "Augustine \($0)", tradition: "Early Church") }
            + [Result(source: "Heidelberg", tradition: "Reformed")]
        let result = diversify(ranked)
        #expect(result.count == 6)
        #expect(result.map(\.tradition).contains("Reformed"))
    }

    @Test func stopsOneSourceMonopolising() {
        let ranked = Array(repeating: Result(source: "City of God", tradition: "Early Church"), count: 8)
            + [Result(source: "Confessions", tradition: "Early Church"),
               Result(source: "Heidelberg", tradition: "Reformed")]
        let result = diversify(ranked)
        #expect(Set(result.map(\.source)).count > 1)
        #expect(result.map(\.source).contains("Heidelberg"))
    }

    @Test func refillsAndPreservesOrder() {
        #expect(diversify(Array(repeating: Result(source: "Only", tradition: "X"), count: 6)).count == 6)
        let varied = [Result(source: "A", tradition: "1"), Result(source: "B", tradition: "2"),
                      Result(source: "C", tradition: "3"), Result(source: "D", tradition: "4")]
        #expect(diversify(varied, limit: 4) == varied)
        #expect(diversify([]).isEmpty)
    }
}

import Foundation
import GRDB
import Testing
@testable import CouncilCore

// The Swift side of shared/golden/search/search.json: every stage of the
// Flutter retrieval code that CouncilCore/Search reproduces on its own, checked
// for every golden query. The README beside the fixture documents the format
// and the tolerances used here. The Flutter side checks the same stages in
// test/search_golden_test.dart.
//
// Parameterised over the queries so a failure names the query id.

@Suite("Search golden fixture")
struct SearchGoldenTests {
    static let tokenizer: WordPieceTokenizer = {
        do {
            return try WordPieceTokenizer(vocabularyAt: Repo.asset("model/vocab.txt"))
        } catch {
            fatalError("Could not load vocab.txt: \(error)")
        }
    }()

    static let index: VectorIndex = {
        do {
            return try GoldenCorpus.database.read { try VectorIndex.load(from: $0) }
        } catch {
            fatalError("Could not load the vector index: \(error)")
        }
    }()

    static let recogniser: EntityRecogniser = {
        do {
            return try GoldenCorpus.database.read { try EntityRecogniser.load(from: $0) }
        } catch {
            fatalError("Could not load the entity recogniser: \(error)")
        }
    }()

    /// `vectorTop` scores: absolute tolerance from the README.
    static let scoreTolerance = 1e-5

    @Test func fixtureMatchesThisCode() {
        let fixture = GoldenSearch.fixture
        #expect(fixture.idSpace == CorpusConstants.idSpace)
        #expect(fixture.embeddingModel == CorpusConstants.embeddingModel)
        #expect(fixture.parameters.rrfK == HybridRanker.k)
        #expect(fixture.parameters.maxTokens == WordPieceTokenizer.maxTokens)
        #expect(fixture.parameters.dims == VectorIndex.dims)
        #expect(fixture.parameters.vectorTopLimit == fixture.parameters.semanticLimit * 6)
        #expect(fixture.queries.count == 37)
    }

    @Test func indexHoldsEveryEmbeddedChunk() {
        #expect(Self.index.count == GoldenSearch.fixture.corpus.vectorIndexLength)
    }

    @Test(arguments: GoldenSearch.queries)
    func tokenIds(_ golden: GoldenQuery) {
        #expect(Self.tokenizer.encode(golden.query) == golden.tokenIds)
    }

    @Test(arguments: GoldenSearch.queries)
    func ftsMatch(_ golden: GoldenQuery) {
        // By scalar: Swift's `==` would accept an NFC/NFD difference.
        let built = QueryShaping.ftsMatchQuery(golden.query)
        #expect(Array(built.unicodeScalars) == Array(golden.ftsMatch.unicodeScalars),
                "\(built) != \(golden.ftsMatch)")
    }

    @Test(arguments: GoldenSearch.queries)
    func tags(_ golden: GoldenQuery) {
        let tags = QueryShaping.extractTags(golden.query)
        #expect(tags == golden.tags)
        #expect(tags.allSatisfy(QueryShaping.tagSlugs.contains))
    }

    @Test(arguments: GoldenSearch.queries)
    func entities(_ golden: GoldenQuery) {
        let entities = Self.recogniser.recognise(golden.query)
        #expect(entities.sourceIds.sorted() == golden.entities.sourceIds)
        #expect(entities.traditionIds.sorted() == golden.entities.traditionIds)
        #expect(entities.labels.map { Array($0.unicodeScalars) }
            == golden.entities.labels.map { Array($0.unicodeScalars) },
            "\(entities.labels) != \(golden.entities.labels)")
    }

    @Test(arguments: GoldenSearch.queries)
    func vectorTop(_ golden: GoldenQuery) {
        let limit = GoldenSearch.fixture.parameters.vectorTopLimit
        let top = Self.index.search(query: golden.floatVector, limit: limit)

        #expect(top.map(\.chunkId) == golden.vectorTop.map(\.chunkId))
        #expect(top.map(\.contentUnitId) == golden.vectorTop.map(\.contentUnitId))
        try? #require(top.count == golden.vectorTop.count)
        for (position, (match, expected)) in zip(top, golden.vectorTop).enumerated() {
            #expect(abs(match.score - expected.score) <= Self.scoreTolerance,
                    "score at \(position): \(match.score) vs \(expected.score)")
        }
    }

    /// The same arithmetic as Dart should give the same bits, not merely
    /// scores inside the tolerance. Not part of the contract (the README allows
    /// 1e-5), but a regression here means the scoring loop changed.
    @Test(arguments: GoldenSearch.queries)
    func vectorTopScoresAreBitIdentical(_ golden: GoldenQuery) {
        let top = Self.index.search(query: golden.floatVector,
                                    limit: GoldenSearch.fixture.parameters.vectorTopLimit)
        #expect(top.map(\.score) == golden.vectorTop.map(\.score))
    }

    @Test(arguments: GoldenSearch.queries)
    func semantic(_ golden: GoldenQuery) {
        let units = Self.index.rankedUnits(query: golden.floatVector,
                                           limit: golden.rag.semanticLimit,
                                           allowedUnitIds: golden.rag.allowedUnitSet)
        #expect(units == golden.rag.semantic)
    }

    @Test(arguments: GoldenSearch.queries)
    func fused(_ golden: GoldenQuery) {
        let fused = HybridRanker.fuse(lexical: golden.rag.lexical,
                                      semantic: golden.rag.semantic,
                                      tags: golden.rag.tagIds,
                                      limit: GoldenSearch.fixture.parameters.fusionLimit)
        #expect(fused == golden.rag.fused)
    }
}

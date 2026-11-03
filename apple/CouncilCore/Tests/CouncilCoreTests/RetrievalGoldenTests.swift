import Foundation
import GRDB
import Testing
@testable import CouncilCore

// The SQL-backed stages of shared/golden/search/search.json: the Read tab's
// `search` (`read`) and every stage of chat retrieval (`rag`), run through the
// real `Retrieval` against the bundled core corpus. SearchGoldenTests covers
// the stages that need no SQL; the README beside the fixture documents the
// format and the tolerances used here.
//
// Semantic ranking uses each query's *recorded* vector, not a re-encoded one.
// The Swift encoder runs a newer ONNX Runtime than the Flutter app, and two of
// the fixture's vectors differ between the two by more than float noise
// (QueryEncoder.swift, "Parity with the Flutter app"), which would make the
// semantic list, and everything fused from it, drift for reasons that have
// nothing to do with retrieval. `RecordedVectorRanker` supplies the recorded
// vector through the same `SemanticRanker` seam `SemanticSearch` fills in the
// app. RetrievalSmokeTests runs the real encoder end to end.

/// Ranks from the fixture's recorded query vectors over the real index.
struct RecordedVectorRanker: SemanticRanker {
    let index: VectorIndex
    /// Keyed by code units: two queries differing only in normalisation are
    /// two queries (`edge-nfd-nicee` is decomposed).
    let vectors: [ExactString: [Float]]

    struct UnknownQuery: Error, CustomStringConvertible {
        let query: String
        var description: String { "No recorded vector for \(query.debugDescription)" }
    }

    init(index: VectorIndex, queries: [GoldenQuery]) {
        self.index = index
        var vectors: [ExactString: [Float]] = [:]
        for query in queries { vectors[ExactString(query.query)] = query.floatVector }
        self.vectors = vectors
    }

    func rankedUnits(for query: String, limit: Int, allowedUnitIds: Set<Int>?) async throws -> [Int] {
        guard let vector = vectors[ExactString(query)] else { throw UnknownQuery(query: query) }
        return index.rankedUnits(query: vector, limit: limit, allowedUnitIds: allowedUnitIds)
    }
}

/// One retrieval per query, shared by the stage tests below so each stage
/// can fail on its own without running the pipeline once per stage.
private actor RetrievalRuns {
    static let shared = RetrievalRuns()

    let retrieval = Retrieval(
        database: GoldenCorpus.database,
        semantic: RecordedVectorRanker(index: SearchGoldenTests.index, queries: GoldenSearch.queries)
    )
    private var runs: [String: Task<RAGRetrieval, any Error>] = [:]

    func rag(_ golden: GoldenQuery) async throws -> RAGRetrieval {
        if let run = runs[golden.id] { return try await run.value }
        let retrieval = self.retrieval
        let limit = GoldenSearch.fixture.parameters.ragLimit
        let run = Task { try await retrieval.retrieve(golden.query, limit: limit) }
        runs[golden.id] = run
        return try await run.value
    }
}

@Suite("Retrieval golden fixture")
struct RetrievalGoldenTests {
    /// FTS `ranks` (bm25): absolute tolerance from the README.
    static let rankTolerance = 1e-5

    static func expectRanks(_ actual: [Double?], _ expected: [Double?], _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        guard actual.count == expected.count else {
            Issue.record("\(what): \(actual.count) ranks, expected \(expected.count)", sourceLocation: sourceLocation)
            return
        }
        for (position, (a, e)) in zip(actual, expected).enumerated() {
            switch (a, e) {
            case (nil, nil):
                continue
            case let (a?, e?) where abs(a - e) <= rankTolerance:
                continue
            default:
                Issue.record("\(what) rank at \(position): \(String(describing: a)) vs \(String(describing: e))",
                             sourceLocation: sourceLocation)
            }
        }
    }

    static func expectCalls(_ actual: [LexicalCall], _ expected: [GoldenQuery.LexicalCall], _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, "\(what): \(actual.map(\.kind)) vs \(expected.map(\.kind))",
                sourceLocation: sourceLocation)
        for (i, (call, golden)) in zip(actual, expected).enumerated() {
            if let kind = golden.kind {
                #expect(call.kind.rawValue == kind, "\(what)[\(i)] kind", sourceLocation: sourceLocation)
            } else {
                // namedTraditionCalls record no kind: they are all scoped FTS.
                #expect(call.kind == .ftsScoped, "\(what)[\(i)] kind", sourceLocation: sourceLocation)
            }
            #expect(call.limit == golden.limit, "\(what)[\(i)] limit", sourceLocation: sourceLocation)
            #expect(call.ids == golden.ids, "\(what)[\(i)] ids", sourceLocation: sourceLocation)
            if golden.kind == "like" {
                // The fixture records no ranks for a LIKE call (`[]`, where
                // `read` writes a null per row): LIKE has none to give.
                #expect(golden.ranks.isEmpty, "\(what)[\(i)] ranks", sourceLocation: sourceLocation)
                #expect(call.rows.allSatisfy { $0.rank == nil }, "\(what)[\(i)] ranks", sourceLocation: sourceLocation)
            } else {
                expectRanks(call.rows.map(\.rank), golden.ranks, "\(what)[\(i)]", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func fixtureLimitsMatchTheChatAndReadScreens() {
        let parameters = GoldenSearch.fixture.parameters
        #expect(parameters.readLimit == 40)
        #expect(parameters.ragLimit == 6)
        #expect(parameters.fusionLimit == parameters.ragLimit * 4)
        #expect(parameters.semanticLimit == parameters.ragLimit * 4)
    }

    // MARK: - Read tab

    @Test(arguments: GoldenSearch.queries)
    func read(_ golden: GoldenQuery) async throws {
        let retrieval = RetrievalRuns.shared.retrieval
        let result = try await retrieval.lexicalSearch(golden.query,
                                                       limit: GoldenSearch.fixture.parameters.readLimit)
        #expect(result.calls.map(\.kind.rawValue) == golden.read.path)
        #expect(result.rows.map(\.id) == golden.read.ids)
        Self.expectRanks(result.rows.map(\.rank), golden.read.ranks, "read")
        // The convenience the Read screen calls returns the same rows.
        let rows = try await retrieval.search(golden.query, limit: GoldenSearch.fixture.parameters.readLimit)
        #expect(rows == result.rows)
    }

    // MARK: - Chat retrieval

    @Test(arguments: GoldenSearch.queries)
    func ragLexicalCalls(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        Self.expectCalls(rag.lexicalCalls, golden.rag.lexicalCalls, "lexicalCalls")
    }

    @Test(arguments: GoldenSearch.queries)
    func ragLexical(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.lexical.map(\.id) == golden.rag.lexical)
        // "The ids of the last entry in lexicalCalls."
        #expect(rag.lexical.map(\.id) == (rag.lexicalCalls.last?.ids ?? []))
    }

    @Test(arguments: GoldenSearch.queries)
    func ragTagIds(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.tags == golden.tags)
        #expect(rag.tagRows.map(\.id) == golden.rag.tagIds)
    }

    @Test(arguments: GoldenSearch.queries)
    func ragAllowedUnitIds(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.semanticAvailable)
        #expect(rag.semanticLimit == golden.rag.semanticLimit)
        // nil (no scope) and [] (a scope admitting nothing) are different.
        #expect(rag.allowedUnitIds == golden.rag.allowedUnitSet)
        #expect(rag.allowedUnitIds?.count == golden.rag.allowedUnitCount)
    }

    @Test(arguments: GoldenSearch.queries)
    func ragSemantic(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.semantic == golden.rag.semantic)
    }

    @Test(arguments: GoldenSearch.queries)
    func ragFused(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.fused == golden.rag.fused)
    }

    @Test(arguments: GoldenSearch.queries)
    func ragNamedTraditionCalls(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        Self.expectCalls(rag.namedTraditionCalls, golden.rag.namedTraditionCalls, "namedTraditionCalls")
    }

    @Test(arguments: GoldenSearch.queries)
    func ragFinal(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        #expect(rag.rows.map(\.id) == golden.rag.final)
        // The convenience the chat screen calls returns the same rows.
        let rows = try await RetrievalRuns.shared.retrieval.searchForRAG(
            golden.query, limit: GoldenSearch.fixture.parameters.ragLimit)
        #expect(rows == rag.rows)
    }

    @Test(arguments: GoldenSearch.queries)
    func ragFinalContent(_ golden: GoldenQuery) async throws {
        let rag = try await RetrievalRuns.shared.rag(golden)
        try #require(rag.rows.count == golden.rag.finalContent.count)
        for (row, expected) in zip(rag.rows, golden.rag.finalContent) {
            #expect(row.id == expected.id)
            // UTF-16 code units, as the README measures them.
            let units = Array(row.content.utf16)
            #expect(units.count == expected.length, "length of \(row.id)")
            #expect(Array(units.prefix(48)) == Array(expected.head.utf16),
                    "head of \(row.id): \(String(decoding: units.prefix(48), as: UTF16.self).debugDescription)")
        }
    }
}

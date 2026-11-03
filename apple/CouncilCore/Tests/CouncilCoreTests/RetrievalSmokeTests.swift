import Foundation
import GRDB
import Testing
@testable import CouncilCore

// Retrieval with the real semantic engine, end to end: WordPiece, the ONNX
// encoder and the vector index composed by `SemanticSearch`, fed to
// `Retrieval` as the app wires them. Not held to the fixture exactly (that is
// RetrievalGoldenTests, which ranks from recorded vectors because the two
// apps' ONNX Runtimes differ slightly); this checks the composition works and
// lands where Flutter's does. Also covers the lexical-only degradation.

/// The real semantic engine, loaded once for the suite.
private actor LiveSemantic {
    static let shared = LiveSemantic()
    static let modelURL = Repo.asset("model/model_quantized.onnx")
    static let vocabularyURL = Repo.asset("model/vocab.txt")

    private var load: Task<SemanticSearch, any Error>?

    /// Fails the calling test, rather than skipping it, when the model is
    /// missing: it is gitignored, and CI fetches it, so a missing model on CI
    /// is a broken setup that must not pass as green.
    static func get() async throws -> SemanticSearch {
        do {
            return try await shared.loaded()
        } catch QueryEncoder.Error.modelNotFound(let url) {
            Issue.record("""
                The embedding model is missing at \(url.path(percentEncoded: false)). \
                It is gitignored; run tools/fetch_model.sh from the repository root.
                """)
            throw QueryEncoder.Error.modelNotFound(url)
        }
    }

    private func loaded() async throws -> SemanticSearch {
        if let load { return try await load.value }
        let task = Task {
            try await SemanticSearch.load(modelURL: Self.modelURL, vocabularyURL: Self.vocabularyURL,
                                          database: GoldenCorpus.database)
        }
        load = task
        return try await task.value
    }
}

/// A spread of query kinds: a reference, a keyword, a pure-meaning question,
/// a scoped question, and the two whose vectors differ most between the apps'
/// runtimes (`ent-catholic`, whose scope admits nothing in the core corpus,
/// and `edge-long`).
private let smokeQueryIDs: Set<String> = [
    "ref-john-3-16", "kw-baptism", "sem-person-saved", "ent-kjv-work", "ent-catholic", "edge-long",
]
private let smokeQueries = GoldenSearch.queries.filter { smokeQueryIDs.contains($0.id) }

@Suite("Retrieval smoke and degradation")
struct RetrievalSmokeTests {
    @Test func smokeQueriesArePresent() {
        #expect(smokeQueries.count == smokeQueryIDs.count)
    }

    @Test func liveIndexHoldsEveryEmbeddedChunk() async throws {
        let semantic = try await LiveSemantic.get()
        #expect(await semantic.vectorCount == GoldenSearch.fixture.corpus.vectorIndexLength)
    }

    @Test("real encoder end to end", arguments: smokeQueries)
    func liveRetrieval(_ golden: GoldenQuery) async throws {
        let semantic = try await LiveSemantic.get()
        let retrieval = Retrieval(database: GoldenCorpus.database, semantic: semantic)
        let rag = try await retrieval.retrieve(golden.query, limit: GoldenSearch.fixture.parameters.ragLimit)

        #expect(rag.semanticAvailable)
        // Empty only where the scope admits nothing (`ent-catholic`).
        #expect(rag.semantic.isEmpty == golden.rag.semantic.isEmpty)
        #expect(!rag.rows.isEmpty)

        // The semantic list should be substantially the Flutter one: at least
        // 80% of the units shared. Measured: identical membership for all of
        // these (cosine >= 0.99997 even for the runtime outliers).
        let shared = Set(rag.semantic).intersection(golden.rag.semantic).count
        #expect(Double(shared) >= 0.8 * Double(golden.rag.semantic.count),
                "\(shared) of \(golden.rag.semantic.count) semantic units shared")

        // And so should the answer.
        let sharedFinal = Set(rag.rows.map(\.id)).intersection(golden.rag.final).count
        #expect(Double(sharedFinal) >= 0.8 * Double(golden.rag.final.count),
                "\(sharedFinal) of \(golden.rag.final.count) final units shared")
    }

    @Test func encodeMatchesTheEncoderOnTokenizedInput() async throws {
        let semantic = try await LiveSemantic.get()
        let golden = try #require(smokeQueries.first)
        let vector = try semantic.encode(golden.query)
        #expect(vector.count == QueryEncoder.dims)
        #expect(vector == (try semantic.encoder.embed(tokenIds: golden.tokenIds)))
    }

    @Test func reloadKeepsAnsweringAndPicksUpTheCorpus() async throws {
        let semantic = try await LiveSemantic.get()
        let before = await semantic.vectorCount
        let retrieval = Retrieval(database: GoldenCorpus.database, semantic: semantic)
        // Overlapping reloads, as two installs in quick succession start;
        // queries keep answering meanwhile.
        async let first: Void = semantic.reload()
        async let second: Void = retrieval.contentDidChange()
        let ranked = try await semantic.rankedUnits(for: "grace", limit: 5)
        try await first
        await second
        #expect(ranked.count == 5)
        #expect(await semantic.vectorCount == before)
    }

    // MARK: - Lexical-only degradation

    @Test func tryLoadReturnsNilWithoutTheModel() async {
        let semantic = await SemanticSearch.tryLoad(
            modelURL: URL(filePath: "/nonexistent/model_quantized.onnx"),
            vocabularyURL: LiveSemantic.vocabularyURL,
            database: GoldenCorpus.database)
        #expect(semantic == nil)
    }

    @Test func tryLoadReturnsNilWithoutAnIndex() async throws {
        // A database with no chunk tables: the model loads, the index can't.
        try #require(FileManager.default.fileExists(atPath: LiveSemantic.modelURL.path(percentEncoded: false)))
        let semantic = await SemanticSearch.tryLoad(
            modelURL: LiveSemantic.modelURL,
            vocabularyURL: LiveSemantic.vocabularyURL,
            database: try DatabaseQueue())
        #expect(semantic == nil)
    }

    /// Without a semantic engine, chat retrieval is the lexical and tag
    /// engines alone, as in the Flutter app when `tryLoad` returns null.
    @Test(arguments: GoldenSearch.queries)
    func lexicalOnly(_ golden: GoldenQuery) async throws {
        let retrieval = Retrieval(database: GoldenCorpus.database)
        let limit = GoldenSearch.fixture.parameters.ragLimit
        let rag = try await retrieval.retrieve(golden.query, limit: limit)

        #expect(!rag.semanticAvailable)
        #expect(rag.semantic.isEmpty)
        // No semantic engine means no scope lookup for it either.
        #expect(rag.allowedUnitIds == nil)
        // The lexical stages don't depend on the semantic engine.
        #expect(rag.lexicalCalls.map(\.ids) == golden.rag.lexicalCalls.map(\.ids))
        #expect(rag.tagRows.map(\.id) == golden.rag.tagIds)
        #expect(rag.fused == HybridRanker.fuse(lexical: golden.rag.lexical, semantic: [],
                                               tags: golden.rag.tagIds, limit: limit * 4))
        #expect(rag.rows.count <= limit)
        #expect(Set(rag.rows.map(\.id)).isSubset(of: Set(rag.fused)))
    }

    @Test func settingTheSemanticEngineLater() async throws {
        let retrieval = Retrieval(database: GoldenCorpus.database)
        #expect(await retrieval.semantic == nil)
        await retrieval.setSemantic(RecordedVectorRanker(index: SearchGoldenTests.index,
                                                         queries: GoldenSearch.queries))
        let golden = try #require(GoldenSearch.queries.first)
        let rag = try await retrieval.retrieve(golden.query, limit: GoldenSearch.fixture.parameters.ragLimit)
        #expect(rag.semanticAvailable)
        #expect(rag.rows.map(\.id) == golden.rag.final)
    }

    @Test func recogniserIsCachedUntilInvalidated() async throws {
        let retrieval = Retrieval(database: GoldenCorpus.database)
        let first = try await retrieval.recogniser()
        let again = try await retrieval.recogniser()
        await retrieval.invalidateRecogniser()
        let fresh = try await retrieval.recogniser()
        // Same content either way; the point is that each call answers.
        let query = "Scripture on prayer"
        #expect(first.recognise(query) == again.recognise(query))
        #expect(fresh.recognise(query) == first.recognise(query))
    }
}

// MARK: - Chunk choice

@Suite("Best chunk text")
struct BestChunkTextTests {
    @Test func singleChunkReturnsTheWholeUnit() {
        #expect(Retrieval.bestChunkText(content: "abc def", chunks: [(0, 3)], query: "def") == "abc def")
    }

    @Test func picksTheChunkWithMostTermsFirstWinningTies() {
        let content = "grace and peace. faith alone. grace through faith."
        let chunks: [(start: Int, end: Int)] = [(0, 16), (17, 29), (30, 51)]
        #expect(Retrieval.bestChunkText(content: content, chunks: chunks, query: "grace faith")
                == "grace through faith.")
        #expect(Retrieval.bestChunkText(content: content, chunks: chunks, query: "peace")
                == "grace and peace.")
        // No term scores: the first chunk still beats the -1 floor.
        #expect(Retrieval.bestChunkText(content: content, chunks: chunks, query: "zzz")
                == "grace and peace.")
    }

    @Test func noUsableTermsReturnsTheWholeUnit() {
        #expect(Retrieval.bestChunkText(content: "ab cd", chunks: [(0, 2), (3, 5)], query: "a b ?") == "ab cd")
    }

    @Test func offsetsAreUTF16AndTermsMatchByCodeUnit() {
        // "é" decomposed: Dart's code-unit `contains` finds "nice" inside it,
        // where Swift's Character comparison would not.
        let content = "Nice\u{301} city. other text."
        let chunks: [(start: Int, end: Int)] = [(0, 11), (12, 23)]
        #expect(Retrieval.bestChunkText(content: content, chunks: chunks, query: "text") == "other text.")
        #expect(Retrieval.bestChunkText(content: content, chunks: chunks, query: "nice") == "Nice\u{301} city.")
        // An emoji is two code units, so offsets after it shift by two.
        let emoji = "😀 grace. faith."
        #expect(Retrieval.bestChunkText(content: emoji, chunks: [(0, 9), (10, 16)], query: "faith") == "faith.")
    }

    @Test func endIsClampedAndEmptyChunksSkipped() {
        let content = "alpha beta"
        #expect(Retrieval.bestChunkText(content: content, chunks: [(6, 6), (6, 999)], query: "beta") == "beta")
    }
}

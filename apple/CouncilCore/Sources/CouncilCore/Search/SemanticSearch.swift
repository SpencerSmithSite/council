// Port of lib/src/services/search/semantic_search.dart: the tokenizer, query
// encoder and vector index composed into one service, loaded non-fatally and
// reloaded after packs change. The Flutter app's newer version moves the scan
// onto a background isolate (`VectorSearchWorker`); here the index is an
// immutable value held by an actor and scanned off the actor, which gives the
// same two properties: nothing heavy on the UI thread, and the old index keeps
// answering while a new one loads.
//
// Golden stage: `rag.semantic`, reached through `Retrieval`.

import Foundation
import GRDB
import os

/// Ranks content units by meaning: the semantic engine chat retrieval fuses
/// with the lexical ones.
///
/// A protocol so retrieval can be handed something other than the live model.
/// The golden tests need that: the Swift encoder runs ONNX Runtime 1.24, the
/// Flutter app 1.15.1, and two of the fixture's query vectors differ between
/// them by more than float noise (shared/golden/search/README.md). Retrieval
/// is held to the fixture exactly by ranking from the *recorded* vectors,
/// which a conformer outside this module supplies, while the production path
/// (`SemanticSearch`) stays the only implementation shipped.
public protocol SemanticRanker: Sendable {
    /// Content unit ids ranked by similarity to `query`, best first, at most
    /// `limit` of them.
    ///
    /// `allowedUnitIds` applies a recognised scope. Both engines must honour
    /// it: scoping only the lexical side lets unscoped semantic hits back in
    /// through fusion, which is how a question about the Council of Trent kept
    /// returning Carthage and Nicaea. An empty set is a scope that admits
    /// nothing and returns nothing; nil is no scope.
    func rankedUnits(for query: String, limit: Int, allowedUnitIds: Set<Int>?) async throws -> [Int]

    /// Re-read whatever the ranker holds of the corpus, after content is
    /// installed or removed. Rankers that hold nothing needn't implement it.
    func reload() async throws
}

extension SemanticRanker {
    public func reload() async throws {}
}

/// Semantic retrieval over the precomputed corpus vectors.
///
/// Kept apart from lexical retrieval on purpose, as in the Flutter app, so
/// the degraded path is explicit: if the model or the index fails to load,
/// `tryLoad` returns nil, `Retrieval` runs without a semantic engine, and
/// search stays lexical rather than the app failing to start.
///
/// ## Concurrency
///
/// An actor only for the one piece of mutable state, the index, which
/// `reload` swaps. Queries don't run *on* the actor: `rankedUnits` takes the
/// current index (an immutable `Sendable` value) and encodes and scans off it,
/// so concurrent queries run in parallel, and a reload in progress never makes
/// a query wait. The scan is ~180M multiply-adds at the full library's
/// ~468,000 chunks, the work the Flutter app moved off its UI isolate after it
/// stalled the screen on every search.
public actor SemanticSearch: SemanticRanker {
    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Search")

    public nonisolated let tokenizer: WordPieceTokenizer
    public nonisolated let encoder: QueryEncoder
    /// The corpus the index is read from, again on every `reload`.
    public nonisolated let database: any DatabaseReader

    private var index: VectorIndex

    /// Ordering for overlapping reloads: see `reload`.
    private var reloadsStarted = 0
    private var reloadApplied = 0

    /// Compose already-loaded parts. `load` and `tryLoad` are the usual way in.
    public init(tokenizer: WordPieceTokenizer, encoder: QueryEncoder,
                database: any DatabaseReader, index: VectorIndex) {
        self.tokenizer = tokenizer
        self.encoder = encoder
        self.database = database
        self.index = index
    }

    /// Chunks in the index as it stands.
    public var vectorCount: Int { index.count }

    /// Load the vocabulary, the model and the vector index.
    ///
    /// The model costs ~20 MB and a moment of startup, and the index is read
    /// from every embedded chunk, so call this off the main actor and after
    /// the corpus is open; lexical search doesn't need to wait for it.
    public static func load(modelURL: URL, vocabularyURL: URL,
                            database: any DatabaseReader) async throws -> SemanticSearch {
        let tokenizer = try WordPieceTokenizer(vocabularyAt: vocabularyURL)
        let encoder = try QueryEncoder(modelURL: modelURL)
        let index = try await database.read { try VectorIndex.load(from: $0) }
        return SemanticSearch(tokenizer: tokenizer, encoder: encoder, database: database, index: index)
    }

    /// `load`, or nil if any part fails, logging why.
    ///
    /// Deliberately non-fatal. Semantic search is an improvement over lexical
    /// search, not a precondition for it, and a device that can't run the
    /// model should still be able to read the library.
    public static func tryLoad(modelURL: URL, vocabularyURL: URL,
                               database: any DatabaseReader) async -> SemanticSearch? {
        do {
            return try await load(modelURL: modelURL, vocabularyURL: vocabularyURL, database: database)
        } catch {
            logger.error("Semantic search unavailable, falling back to lexical: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Rebuild the in-memory index from the database.
    ///
    /// The index is a resident snapshot, so content installed afterwards is
    /// invisible to semantic search until this is called. That failure is
    /// quiet in the worst way: lexical search finds the new text, so the pack
    /// looks installed, while half of retrieval silently ignores it.
    ///
    /// The old index keeps answering until the new one is loaded, so a search
    /// during a pack install sees the previous library rather than none. That
    /// briefly holds two indexes in memory, as the Flutter worker does.
    ///
    /// Two installs in quick succession start two reloads, and the earlier one
    /// can finish last. Its snapshot predates the later install, so it is
    /// dropped if a later reload has already been applied. If a later one
    /// failed, the earlier one still applies: it is newer than what's there.
    /// A failure leaves the current index in place and throws.
    public func reload() async throws {
        reloadsStarted += 1
        let ticket = reloadsStarted
        let fresh = try await database.read { try VectorIndex.load(from: $0) }
        guard ticket > reloadApplied else { return }
        index = fresh
        reloadApplied = ticket
    }

    /// WordPiece-tokenize and encode `query` to the model's 384 L2-normalised
    /// floats. Blocks for a few milliseconds of inference; call it off the
    /// main actor.
    ///
    /// Empty input still encodes (`[CLS] [SEP]`), and so still ranks: the
    /// golden `edge-empty` query returns semantic results while the Read tab's
    /// search for the same text returns nothing.
    public nonisolated func encode(_ query: String) throws -> [Float] {
        try encoder.embed(tokenIds: tokenizer.encode(query))
    }

    /// Content unit ids ranked by semantic similarity, best first; see
    /// `SemanticRanker.rankedUnits` and `VectorIndex.rankedUnits` (which asks
    /// the index for `limit * 6` chunks, since several chunks of one long
    /// work routinely occupy the top of the list and collapse to one unit).
    public nonisolated func rankedUnits(for query: String, limit: Int = 30,
                                        allowedUnitIds: Set<Int>? = nil) async throws -> [Int] {
        let vector = try encode(query)
        let index = await self.index
        return index.rankedUnits(query: vector, limit: limit, allowedUnitIds: allowedUnitIds)
    }
}

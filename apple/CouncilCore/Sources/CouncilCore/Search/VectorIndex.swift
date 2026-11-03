// Port of lib/src/services/search/vector_index.dart, plus the pure half of
// `SemanticSearch.rankedUnits` from lib/src/services/search/semantic_search.dart
// (the half that runs after the query has been encoded).
//
// Golden stages: `vectorTop` (from the fixture's `vector`) and `rag.semantic`.

import Foundation
import GRDB

/// One scored chunk from the vector index.
public struct ChunkMatch: Sendable, Hashable {
    public let chunkId: Int
    public let contentUnitId: Int
    public let charStart: Int
    public let charEnd: Int
    public let score: Double

    public init(chunkId: Int, contentUnitId: Int, charStart: Int, charEnd: Int, score: Double) {
        self.chunkId = chunkId
        self.contentUnitId = contentUnitId
        self.charStart = charStart
        self.charEnd = charEnd
        self.score = score
    }

    public func withScore(_ newScore: Double) -> ChunkMatch {
        ChunkMatch(chunkId: chunkId, contentUnitId: contentUnitId,
                   charStart: charStart, charEnd: charEnd, score: newScore)
    }
}

/// In-memory nearest-neighbour search over the precomputed chunk embeddings.
///
/// The vectors are L2-normalized and quantized to int8 at build time, so
/// cosine similarity is just a dot product, and the whole index is small enough
/// to hold resident and scan exhaustively (~165 MB at 430,000 chunks). At this
/// scale an approximate index (HNSW, IVF) would add a dependency and a build
/// step to save a few milliseconds.
///
/// An immutable value: build it once with `load(from:)` off the main actor and
/// hand it to whatever owns retrieval. Rebuild it after installing a pack —
/// the index is a snapshot, and content installed afterwards is invisible to
/// semantic search until it is reloaded, while lexical search finds it, so the
/// pack looks installed while half of retrieval silently ignores it.
public struct VectorIndex: Sendable {
    public static let dims = SearchConstants.vectorDims

    /// Quantization scale used by tools/build_embeddings.py.
    private static let scale = 127.0

    public enum LoadError: Error, Equatable {
        /// A `chunk_embeddings.vector` blob shorter than `dims` bytes.
        case malformedVector(chunkId: Int, byteCount: Int)
    }

    private let vectors: [Int8]
    private let chunkIds: [Int]
    private let unitIds: [Int]
    private let starts: [Int]
    private let ends: [Int]

    public var count: Int { chunkIds.count }

    /// Load the index from the corpus: every `chunk_embeddings` row joined to
    /// its `content_chunks` row, in `chunk_id` order.
    ///
    /// The order matters beyond tidiness: `search` keeps the earlier chunk
    /// first when two score the same, so a different load order changes which
    /// of two tied chunks survives the cut.
    ///
    /// The Dart version pages this query 20,000 rows at a time, keyset on
    /// `chunk_id`. That exists because sqflite marshals a whole result set
    /// across the platform channel as a `List<Map>` before the first row is
    /// read and serialises every database operation through one queue: at
    /// 430,000 chunks the single query blocked the app's database for around
    /// four minutes. A GRDB cursor steps the statement row by row with no
    /// materialised result set, so one ordered query visits the same rows in
    /// the same order without that cost. Run it in a read (`DatabasePool.read`)
    /// so it doesn't hold the writer.
    public static func load(from db: Database) throws -> VectorIndex {
        let expected = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_embeddings") ?? 0

        var vectors = [Int8](repeating: 0, count: expected * dims)
        var chunkIds: [Int] = []
        var unitIds: [Int] = []
        var starts: [Int] = []
        var ends: [Int] = []
        chunkIds.reserveCapacity(expected)
        unitIds.reserveCapacity(expected)
        starts.reserveCapacity(expected)
        ends.reserveCapacity(expected)

        let rows = try Row.fetchCursor(db, sql: """
            SELECT e.chunk_id, e.vector, c.content_unit_id, c.char_start, c.char_end
            FROM chunk_embeddings e
            JOIN content_chunks c ON e.chunk_id = c.id
            ORDER BY e.chunk_id
            """)

        var i = 0
        try vectors.withUnsafeMutableBytes { buffer in
            while let row = try rows.next() {
                // The count and the join can disagree if a chunk lost its
                // parent; stop rather than write past the end of the buffer.
                if i >= expected { break }
                let chunkId: Int = row[0]
                try row.withUnsafeData(atIndex: 1) { data in
                    let data = data ?? Data()
                    guard data.count >= dims else {
                        throw LoadError.malformedVector(chunkId: chunkId, byteCount: data.count)
                    }
                    let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[(i * dims)..<(i * dims + dims)])
                    data.copyBytes(to: destination, from: 0..<dims)
                }
                chunkIds.append(chunkId)
                unitIds.append(row[2])
                starts.append(row[3])
                ends.append(row[4])
                i += 1
            }
        }

        // A chunk whose parent unit is gone yields fewer rows than the count.
        // Trim rather than leave zeroed vectors, which would score as valid
        // neighbours.
        if i < expected {
            vectors.removeSubrange((i * dims)...)
        }

        return VectorIndex(vectors: vectors, chunkIds: chunkIds, unitIds: unitIds,
                           starts: starts, ends: ends)
    }

    private init(vectors: [Int8], chunkIds: [Int], unitIds: [Int], starts: [Int], ends: [Int]) {
        self.vectors = vectors
        self.chunkIds = chunkIds
        self.unitIds = unitIds
        self.starts = starts
        self.ends = ends
    }

    /// Top `limit` chunks by cosine similarity to `query`, best first.
    ///
    /// `query` must be L2-normalized and produced by the same model that built
    /// the index — vectors from a different model are not comparable.
    ///
    /// The arithmetic is the Dart code's, operation for operation, so scores
    /// are bit-identical and ties fall the same way: each component is
    /// `Double(int8) * Double(float32)`, summed in a Double sequentially over
    /// `d = 0..<384`, then divided by 127. Do not replace the loop with vDSP or
    /// Float SIMD: a float32 or reordered accumulation changes the low bits,
    /// and the golden fixture has neighbouring scores 2.5e-8 apart.
    ///
    /// Insertion into the top list is stable — a later chunk with an equal
    /// score goes after the earlier one — and a chunk is admitted while the
    /// list is short or when it strictly beats the current last place.
    public func search(query: [Float], limit: Int = 20) -> [ChunkMatch] {
        precondition(query.count == Self.dims, "query must be \(Self.dims)-dimensional")
        // Dart throws on an empty list here (`best.last`); nothing asked for
        // is a valid answer.
        guard limit > 0 else { return [] }

        // Float -> Double is exact, so converting once up front is the same
        // arithmetic as converting inside the loop.
        let q = query.map { Double($0) }
        let dims = Self.dims
        let scale = Self.scale

        // A small heap would be tidier, but with the limits used here an
        // insertion into a sorted list of that size is cheaper than heap
        // bookkeeping.
        var best: [ChunkMatch] = []
        best.reserveCapacity(limit + 1)
        var floor = -2.0

        vectors.withUnsafeBufferPointer { vectors in
            q.withUnsafeBufferPointer { q in
                for i in 0..<chunkIds.count {
                    let base = i * dims
                    var dot = 0.0
                    for d in 0..<dims {
                        dot += Double(vectors[base + d]) * q[d]
                    }
                    let score = dot / scale

                    if best.count < limit || score > floor {
                        let match = ChunkMatch(chunkId: chunkIds[i], contentUnitId: unitIds[i],
                                               charStart: starts[i], charEnd: ends[i], score: score)
                        var at = best.count
                        while at > 0 && best[at - 1].score < score {
                            at -= 1
                        }
                        best.insert(match, at: at)
                        if best.count > limit { best.removeLast() }
                        floor = best[best.count - 1].score
                    }
                }
            }
        }

        return best
    }

    /// Content unit ids ranked by semantic similarity to `query`, best first:
    /// `SemanticSearch.rankedUnits` once the query is encoded.
    ///
    /// Asks the index for `limit * 6` chunks, because several chunks of one
    /// long work routinely occupy the top of the list and they collapse to a
    /// single unit.
    ///
    /// `allowedUnitIds` applies a recognised scope. Both engines must honour
    /// it: scoping only the lexical side lets unscoped semantic hits back in
    /// through fusion, which is how a question about the Council of Trent kept
    /// returning Carthage and Nicaea. An empty set is a scope that admits
    /// nothing, and returns nothing; `nil` is no scope.
    public func rankedUnits(query: [Float], limit: Int = 30, allowedUnitIds: Set<Int>? = nil) -> [Int] {
        Self.rankedUnits(from: search(query: query, limit: limit * 6),
                         limit: limit, allowedUnitIds: allowedUnitIds)
    }

    /// The filtering half of `rankedUnits`: matches in order, outside the
    /// scope dropped, one entry per unit at its first position, cut at `limit`.
    public static func rankedUnits(from matches: [ChunkMatch], limit: Int,
                                   allowedUnitIds: Set<Int>? = nil) -> [Int] {
        var units: [Int] = []
        var seen = Set<Int>()
        for match in matches {
            if let allowedUnitIds, !allowedUnitIds.contains(match.contentUnitId) { continue }
            if seen.insert(match.contentUnitId).inserted {
                units.append(match.contentUnitId)
                if units.count >= limit { break }
            }
        }
        return units
    }
}

import Foundation
import Testing

/// shared/golden/search/search.json, decoded. Only the fields the Swift tests
/// check are modelled; shared/golden/search/README.md documents the rest.
struct GoldenSearchFixture: Decodable, Sendable {
    let corpusVersion: Int
    let idSpace: Int
    let embeddingModel: String
    let corpus: Corpus
    let parameters: Parameters
    let queries: [GoldenQuery]

    struct Corpus: Decodable, Sendable {
        let vectorIndexLength: Int
    }

    struct Parameters: Decodable, Sendable {
        let ragLimit: Int
        let readLimit: Int
        let fusionLimit: Int
        let semanticLimit: Int
        let vectorTopLimit: Int
        let rrfK: Double
        let maxTokens: Int
        let dims: Int
    }
}

struct GoldenQuery: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let query: String
    let tokenIds: [Int]
    /// float32 values written as the shortest decimal that round-trips, so
    /// read as Double and narrowed (see `floatVector`).
    let vector: [Double]
    let vectorTop: [VectorHit]
    let entities: Entities
    let ftsMatch: String
    let tags: [String]
    let read: Read
    let rag: Rag

    var floatVector: [Float] { vector.map { Float($0) } }

    var testDescription: String { id }

    struct VectorHit: Decodable, Sendable {
        let chunkId: Int
        let contentUnitId: Int
        let score: Double

        init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            chunkId = try row.decode(Int.self)
            contentUnitId = try row.decode(Int.self)
            score = try row.decode(Double.self)
        }
    }

    struct Entities: Decodable, Sendable {
        let sourceIds: [Int]
        let traditionIds: [Int]
        let labels: [String]
    }

    /// The Read tab's `search(query, limit: 40)`.
    struct Read: Decodable, Sendable {
        /// The queries that ran, in order: `fts`, `like`.
        let path: [String]
        let ids: [Int]
        /// bm25 per row, `nil` for rows from the LIKE fallback.
        let ranks: [Double?]
    }

    /// One lexical query `searchForRAG` ran. `kind` is absent from
    /// `namedTraditionCalls`, which are all scoped FTS.
    struct LexicalCall: Decodable, Sendable {
        let kind: String?
        let limit: Int
        let ids: [Int]
        let ranks: [Double?]
    }

    /// Per returned row, the chunk `_bestChunkText` chose, measured in UTF-16
    /// code units.
    struct FinalContent: Decodable, Sendable {
        let id: Int
        let length: Int
        let head: String
    }

    struct Rag: Decodable, Sendable {
        let lexicalCalls: [LexicalCall]
        let lexical: [Int]
        let tagIds: [Int]
        let semanticLimit: Int
        /// Inclusive `[start, end]` runs; `nil` is no scope, `[]` admits nothing.
        let allowedUnitIds: [[Int]]?
        let allowedUnitCount: Int?
        let semantic: [Int]
        let fused: [Int]
        let namedTraditionCalls: [LexicalCall]
        let final: [Int]
        let finalContent: [FinalContent]

        var allowedUnitSet: Set<Int>? {
            allowedUnitIds.map { runs in
                var ids = Set<Int>()
                for run in runs { ids.formUnion(run[0]...run[1]) }
                return ids
            }
        }
    }
}

enum GoldenSearch {
    static let fixture: GoldenSearchFixture = {
        let url = Repo.golden("search/search.json")
        do {
            return try JSONDecoder().decode(GoldenSearchFixture.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Could not decode \(url.path): \(error)")
        }
    }()

    static var queries: [GoldenQuery] { fixture.queries }
}

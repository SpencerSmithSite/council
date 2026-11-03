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

    struct Rag: Decodable, Sendable {
        let lexical: [Int]
        let tagIds: [Int]
        let semanticLimit: Int
        /// Inclusive `[start, end]` runs; `nil` is no scope, `[]` admits nothing.
        let allowedUnitIds: [[Int]]?
        let semantic: [Int]
        let fused: [Int]

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

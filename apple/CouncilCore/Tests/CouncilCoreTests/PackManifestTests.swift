// Mirrors test/pack_manifest_test.dart and test/pack_embedding_guard_test.dart,
// plus the HTTP failure paths of PackService.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// Parsing the published manifest, and the arithmetic the library screen shows.
@Suite struct PackManifestTests {
    static let body = """
      {
        "corpusVersion": 5,
        "idSpace": 2,
        "fragments": [
          {"id": "f-augustine", "file": "f-augustine.db.gz", "bytes": 4194304,
           "sha256": "aa", "sources": 44, "units": 2496, "chunks": 7179},
          {"id": "f-chrysostom", "file": "f-chrysostom.db.gz", "bytes": 6291456,
           "sha256": "bb", "sources": 36, "units": 2932, "chunks": 9704}
        ],
        "collections": [
          {"id": "author-augustine", "kind": "author", "name": "Augustine of Hippo",
           "description": "The complete Augustine.", "fragments": ["f-augustine"]},
          {"id": "nicene", "kind": "era", "name": "Nicene Writers",
           "description": "", "fragments": ["f-augustine", "f-chrysostom"]}
        ]
      }
      """

    @Test func readsFragmentsCollectionsAndTheIdSpace() throws {
        let manifest = try PackManifest.parse(Self.body)
        #expect(manifest.corpusVersion == 5)
        #expect(manifest.idSpace == 2)
        #expect(manifest.fragments.count == 2)
        #expect(manifest.collections.count == 2)
        #expect(manifest.collections.first?.kind == .author)
        #expect(manifest.fragment("f-augustine")?.units == 2496)
        #expect(manifest.embeddingModel == nil)
    }

    @Test func costIsEverythingWhenNothingIsInstalled() throws {
        let manifest = try PackManifest.parse(Self.body)
        let nicene = try #require(manifest.collection("nicene"))
        #expect(manifest.bytesToInstall(nicene, installedFragments: []) == 4194304 + 6291456)
        #expect(PackManifest.formatBytes(manifest.bytesToInstall(nicene, installedFragments: [])) == "10.0 MB")
    }

    @Test func costIsOnlyTheMissingFragmentWhenOneIsHeld() throws {
        // The whole reason fragments exist: a reader who already has Augustine
        // must not be quoted — or charged — for him a second time.
        let manifest = try PackManifest.parse(Self.body)
        let nicene = try #require(manifest.collection("nicene"))
        #expect(manifest.bytesToInstall(nicene, installedFragments: ["f-augustine"]) == 6291456)
        #expect(manifest.bytesToInstall(nicene, installedFragments: ["f-augustine", "f-chrysostom"]) == 0)
    }

    @Test func anUnknownFragmentContributesNothingRatherThanThrowing() throws {
        // An older app reading a newer manifest should degrade, not crash.
        let manifest = try PackManifest.parse(Self.body)
        let stale = PackManifest(
            corpusVersion: 5,
            idSpace: 2,
            fragments: manifest.fragments,
            collections: [PackCollection(id: "x", name: "X", fragments: ["f-augustine", "f-new"])]
        )
        #expect(stale.bytesToInstall(stale.collections[0], installedFragments: []) == 4194304)
    }

    @Test func aCatalogueWithNoIdSpaceIsReadAsTheFirstOne() throws {
        // Every catalogue published before packs were decoupled from app
        // releases omits the field, and they all belong to the id space that
        // was numbered 1 at the build where the ledger began. Defaulting to 0,
        // or throwing, would make the app refuse content it can install.
        let manifest = try PackManifest.parse("""
            {
              "corpusVersion": 12,
              "fragments": [
                {"id": "f-anglican", "file": "f-anglican.db.gz", "bytes": 40960,
                 "sha256": "cc", "sources": 1, "units": 39, "chunks": 57}
              ],
              "collections": []
            }
            """)
        #expect(manifest.idSpace == 1)
    }

    @Test func optionalFieldsDefaultAsInDart() throws {
        let manifest = try PackManifest.parse("""
            {"corpusVersion": 1, "idSpace": null, "embeddingModel": null,
             "fragments": [{"id": "f", "file": "f.db.gz", "bytes": 1, "sha256": "x"}],
             "collections": [{"id": "c", "name": "C", "kind": "something-new", "fragments": []}]}
            """)
        #expect(manifest.idSpace == 1)
        #expect(manifest.fragments[0] == PackFragment(id: "f", file: "f.db.gz", bytes: 1, sha256: "x"))
        #expect(manifest.collections[0].kind == .other)
        #expect(manifest.collections[0].description == "")
    }

    @Test func aMalformedManifestThrowsRatherThanYieldingAnEmptyCatalogue() {
        // Returning nothing would render as "no content is published yet",
        // which is indistinguishable from a healthy empty library.
        #expect(throws: (any Error).self) { try PackManifest.parse("not json") }
        #expect(throws: (any Error).self) { try PackManifest.parse(#"{"fragments": []}"#) }
    }

    @Test func sizesReadAsTheLibraryShowsThem() {
        #expect(PackManifest.formatBytes(512) == "512 B")
        #expect(PackManifest.formatBytes(1024) == "1 KB")
        #expect(PackManifest.formatBytes(1536) == "2 KB")
        #expect(PackManifest.formatBytes(1024 * 1024) == "1.0 MB")
        #expect(PackManifest.formatBytes(35_546_726) == "33.9 MB")
    }

    @Test func embeddingCompatibility() throws {
        let base = try PackManifest.parse(Self.body)
        #expect(base.embeddingsCompatible(with: CorpusConstants.embeddingModel), "no identity is trusted")
        let other = PackManifest(corpusVersion: 1, idSpace: 2, embeddingModel: "other", fragments: [], collections: [])
        #expect(!other.embeddingsCompatible(with: CorpusConstants.embeddingModel))
    }
}

/// PackService's gates and its HTTP failure paths, with a stub fetcher.
@Suite struct PackServiceTests {
    let root: URL
    let database: DatabaseQueue

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "council-packs-\(UUID().uuidString)", directoryHint: .isDirectory)
        database = try DatabaseQueue(configuration: Corpus.configuration())
        try database.write { try PackService.createTables($0) }
    }

    func service(_ fetcher: StubFetcher, manifestURL: URL = PackEndpoints.defaultManifestURL) -> PackService {
        PackService(database: database, workspace: PackService.workspace(in: root), fetcher: fetcher, manifestURL: manifestURL)
    }

    static func manifest(embeddingModel: String?, idSpace: Int = CorpusConstants.idSpace) throws -> PackManifest {
        let model = embeddingModel.map { #""embeddingModel": "\#($0)","# } ?? ""
        return try PackManifest.parse("""
            {
              "corpusVersion": 16,
              "idSpace": \(idSpace),
              \(model)
              "fragments": [
                {"id": "f-augustine", "file": "f-augustine.db.gz", "bytes": 1024,
                 "sha256": "aa", "sources": 1, "units": 1, "chunks": 1}
              ],
              "collections": [
                {"id": "author-augustine", "kind": "author", "name": "Augustine of Hippo",
                 "description": "", "fragments": ["f-augustine"]}
              ]
            }
            """)
    }

    // An installed pack's vectors must have been built by the model this app
    // encodes queries with. The failure it guards against is silent: vectors
    // from one model compared against queries from another are noise, and
    // every checksum, row count and fragment record stays correct while
    // semantic retrieval stops working.

    @Test func aPackBuiltByADifferentEmbeddingModelIsRefusedBeforeAnyDownload() async throws {
        let fetcher = StubFetcher(status: 200)
        let manifest = try Self.manifest(embeddingModel: "some-other-model-v9")
        await #expect(throws: PackError.incompatibleEmbeddingModel) {
            try await service(fetcher).install(manifest.collections[0], from: manifest)
        }
        #expect(PackError.incompatibleEmbeddingModel.message.contains("Update the app"))
        #expect(await fetcher.requested.isEmpty)
    }

    @Test func aManifestNamingThisBuildsModelGetsPastTheGate() async throws {
        // It then fails on the download, which is the point: not refused for
        // its model.
        let fetcher = StubFetcher(status: 404)
        for model in [CorpusConstants.embeddingModel, nil] {
            let manifest = try Self.manifest(embeddingModel: model)
            await #expect(throws: PackError.downloadFailed(status: 404)) {
                try await service(fetcher).install(manifest.collections[0], from: manifest)
            }
        }
    }

    @Test func anotherIdSpaceIsRefusedBeforeAnyDownload() async throws {
        let fetcher = StubFetcher(status: 200)
        let manifest = try Self.manifest(embeddingModel: nil, idSpace: 3)
        await #expect(throws: PackError.differentIdSpace) {
            try await service(fetcher).install(manifest.collections[0], from: manifest)
        }
        #expect(await fetcher.requested.isEmpty)
    }

    @Test func catalogueFailuresSayWhatHappened() async throws {
        await #expect(throws: PackError.catalogueUnavailable(status: 503)) {
            try await service(StubFetcher(status: 503)).fetchManifest()
        }
        await #expect(throws: PackError.catalogueTimedOut) {
            try await service(StubFetcher(timesOut: true)).fetchManifest()
        }
        #expect(PackError.catalogueUnavailable(status: 503).message == "Could not reach the library catalogue (HTTP 503).")
    }

    @Test func aDownloadThatTimesOutNamesTheFragmentAndLeavesNothingBehind() async throws {
        let manifest = try Self.manifest(embeddingModel: nil)
        await #expect(throws: PackError.downloadTimedOut(fragment: "f-augustine")) {
            try await service(StubFetcher(timesOut: true)).install(manifest.collections[0], from: manifest)
        }
        #expect(PackError.downloadTimedOut(fragment: "f-augustine").message
            == "Could not start downloading f-augustine: the connection timed out.")
        let workspace = PackService.workspace(in: root)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: workspace.path))?.isEmpty ?? true)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func fragmentURLsReplaceTheFirstManifestJSON() throws {
        let fragment = PackFragment(id: "f", file: "f-x.db.gz", bytes: 1, sha256: "")
        let real = service(StubFetcher(status: 200))
        #expect(real.downloadURL(for: fragment).absoluteString
            == "https://github.com/SpencerSmithSite/council/releases/latest/download/f-x.db.gz")
        // Dart's replaceFirst: only the first occurrence, and a URL without one
        // is left as it is.
        let odd = service(StubFetcher(status: 200), manifestURL: URL(string: "https://h/manifest.json/manifest.json")!)
        #expect(odd.downloadURL(for: fragment).absoluteString == "https://h/f-x.db.gz/manifest.json")
        let none = service(StubFetcher(status: 200), manifestURL: URL(string: "https://h/catalogue")!)
        #expect(none.downloadURL(for: fragment).absoluteString == "https://h/catalogue")
    }

    @Test func timestampsLookLikeDartsToIso8601String() {
        let text = PackService.timestamp(Date(timeIntervalSince1970: 1_800_000_000.25))
        #expect(text.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.250/) != nil, "\(text)")
        let micro = PackService.timestamp(Date(timeIntervalSince1970: 1_800_000_000.123456))
        #expect(micro.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}/) != nil, "\(micro)")
    }
}

/// Answers every request with one status, or times out.
actor StubFetcher: PackFetcher {
    let status: Int
    let timesOut: Bool
    private(set) var requested: [URL] = []

    init(status: Int = 200, timesOut: Bool = false) {
        self.status = status
        self.timesOut = timesOut
    }

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        requested.append(url)
        if timesOut { throw PackFetcherError.timedOut }
        return (status, Data())
    }

    func download(_ url: URL, to destination: URL, progress: @Sendable (Int) -> Void) async throws -> Int {
        requested.append(url)
        if timesOut { throw PackFetcherError.timedOut }
        return status
    }
}

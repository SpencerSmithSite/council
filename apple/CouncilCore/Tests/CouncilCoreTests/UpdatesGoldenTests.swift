import Foundation
import Testing
@testable import CouncilCore

// The Swift side of shared/golden/updates/updates.json: what the Flutter app's
// lib/src/services/updates/ (app_version.dart, release_manifest.dart) makes of
// version strings, orderings, download file names and whole manifests. The
// Flutter side writes and checks the same file in
// test/updates_golden_test.dart; the README beside the fixture documents it.
//
// Both apps read the one updates.json on the site, so they have to agree on
// what it offers, quirks of Dart's number parsing and type casts included.

struct GoldenVersion: Decodable, Sendable, Equatable {
    let parts: [Int]
    let build: Int
    let name: String
    let string: String

    init(parts: [Int], build: Int, name: String, string: String) {
        self.parts = parts
        self.build = build
        self.name = name
        self.string = string
    }

    init(_ version: AppVersion) {
        self.init(parts: version.parts, build: version.build, name: version.name, string: version.description)
    }
}

struct GoldenVersionCase: Decodable, Sendable, CustomTestStringConvertible {
    let raw: String?
    let build: Int?
    let result: GoldenVersion?
    var testDescription: String { "\(raw.map { "\"\($0)\"" } ?? "null") build \(build.map(String.init) ?? "-")" }
}

struct GoldenComparisonCase: Decodable, Sendable, CustomTestStringConvertible {
    let a: String
    let b: String
    let order: Int
    let equal: Bool
    var testDescription: String { "\(a) vs \(b)" }
}

struct GoldenFileNameCase: Decodable, Sendable, CustomTestStringConvertible {
    let url: String
    let fileName: String
    var testDescription: String { url }
}

struct GoldenManifestCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Release: Decodable, Sendable {
        let platform: String
        let delivery: String
        let url: String
        let version: GoldenVersion
        let bytes: Int?
        let sha256: String?
        let megabytes: Int
        let fileName: String
    }

    struct Parsed: Decodable, Sendable {
        let version: GoldenVersion
        let notes: String?
        let page: String?
        let platforms: [String: Release]
    }

    let id: String
    let json: String
    let result: Parsed?
    var testDescription: String { id }
}

private struct GoldenUpdatesFile: Decodable {
    let versions: [GoldenVersionCase]
    let comparisons: [GoldenComparisonCase]
    let fileNames: [GoldenFileNameCase]
    let manifests: [GoldenManifestCase]
}

enum GoldenUpdates {
    fileprivate static let file: GoldenUpdatesFile = {
        let data = try! Data(contentsOf: Repo.golden("updates/updates.json"))
        return try! JSONDecoder().decode(GoldenUpdatesFile.self, from: data)
    }()

    static var versions: [GoldenVersionCase] { file.versions }
    static var comparisons: [GoldenComparisonCase] { file.comparisons }
    static var fileNames: [GoldenFileNameCase] { file.fileNames }
    static var manifests: [GoldenManifestCase] { file.manifests }
}

@Suite struct UpdatesGoldenTests {
    @Test func theFixtureHasCases() {
        #expect(GoldenUpdates.versions.count > 40)
        #expect(GoldenUpdates.manifests.count > 50)
        #expect(GoldenUpdates.manifests.contains { $0.result == nil }, "some manifests must fail")
    }

    @Test(arguments: GoldenUpdates.versions)
    func version(_ golden: GoldenVersionCase) {
        let parsed = AppVersion(parsing: golden.raw, build: golden.build)
        #expect(parsed.map(GoldenVersion.init) == golden.result)
    }

    @Test(arguments: GoldenUpdates.comparisons)
    func comparison(_ golden: GoldenComparisonCase) throws {
        let a = try #require(AppVersion(parsing: golden.a))
        let b = try #require(AppVersion(parsing: golden.b))
        #expect(a.compare(b) == golden.order)
        #expect((a == b) == golden.equal)
        #expect((a < b) == (golden.order < 0))
        #expect((a > b) == (golden.order > 0))
        if golden.equal {
            #expect(a.hashValue == b.hashValue, "equal versions must hash alike")
        }
    }

    @Test(arguments: GoldenUpdates.fileNames)
    func fileName(_ golden: GoldenFileNameCase) throws {
        let release = PlatformRelease(platform: "macos", delivery: .download,
                                      url: try #require(URL(string: golden.url)),
                                      version: AppVersion([2026, 8, 2], build: 7))
        #expect(release.fileName == golden.fileName)
    }

    @Test(arguments: GoldenUpdates.manifests)
    func manifest(_ golden: GoldenManifestCase) throws {
        let parsed = try? ReleaseManifest.parse(Data(golden.json.utf8))
        guard let expected = golden.result else {
            #expect(parsed == nil, "Dart refuses this manifest")
            return
        }
        let manifest = try #require(parsed, "Dart accepts this manifest")
        #expect(GoldenVersion(manifest.version) == expected.version)
        #expect(manifest.notes == expected.notes)
        #expect(manifest.page?.absoluteString == expected.page)
        #expect(manifest.platforms.keys.sorted() == expected.platforms.keys.sorted())
        for (id, want) in expected.platforms {
            let got = try #require(manifest.platforms[id])
            #expect(got.platform == want.platform, "\(id)")
            #expect(got.delivery.rawValue == want.delivery, "\(id)")
            #expect(got.url.absoluteString == want.url, "\(id)")
            #expect(GoldenVersion(got.version) == want.version, "\(id)")
            #expect(got.bytes == want.bytes, "\(id)")
            #expect(got.sha256 == want.sha256, "\(id)")
            #expect(got.megabytes == want.megabytes, "\(id)")
            #expect(got.fileName == want.fileName, "\(id)")
        }
    }
}

// Mirrors test/pack_golden_test.dart.

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// The pack golden fixtures in shared/golden/packs/, replayed through the real
/// PackService.
///
/// This app reimplements pack download, verification and merge, and has to end
/// up with exactly the database the Flutter app ends up with. The fixtures are
/// the contract: a tiny bundled core, packs cut from it by
/// tools/build_packs.py, and the expected tables after every step of every
/// scenario in `scenarios.json`. The Flutter app's test/pack_golden_test.dart
/// replays the same file; if this fails after a change to PackService, either
/// the change is a regression or the fixtures were regenerated
/// (`python3 tools/build_pack_goldens.py`) and this side has to follow. See the
/// README there for what each file is.
///
/// Fragments are served by a fetcher reading the scenario's directory, so
/// download, checksum, gunzip, ATTACH and merge all run for real against the
/// fixture bytes; only the socket is replaced. The database is a
/// `DatabasePool` on a temporary file with the corpus's own configuration, so
/// WAL and foreign-keys-off are what is being tested, as in the app.
@Suite struct PackGoldenTests {
    static let plan: OrderedJSON = readJSON("scenarios.json")
    static let appIdSpace: Int = plan["appIdSpace"]!.int
    static let baseState: OrderedJSON = readJSON(plan["baseState"]!.string)
    static let tables: [String] = baseState["tables"]!.keys
    static let scenarioNames: [String] = plan["scenarios"]!.array.map { $0["name"]!.string }

    static func readJSON(_ relative: String) -> OrderedJSON {
        // swiftlint:disable:next force_try
        try! OrderedJSON.parse(Data(contentsOf: Repo.golden("packs").appending(path: relative)))
    }

    // MARK: - The fixtures

    @Test func fixturesDescribeThisBuildOfTheApp() {
        // A fixture for another id space or embedding model would be testing a
        // gate this app does not have. Regenerate after changing either.
        #expect(Self.appIdSpace == CorpusConstants.idSpace)
        #expect(Self.plan["appEmbeddingModel"]?.string == CorpusConstants.embeddingModel)
        let published = Self.readJSON("manifest.json")
        #expect(published["idSpace"]?.int == CorpusConstants.idSpace)
        #expect(published["embeddingModel"]?.string == CorpusConstants.embeddingModel)
    }

    @Test func checksumsMatchTheirFilesButForTheOneCorruptedOnPurpose() throws {
        var mismatched: [String] = []
        for scenario in Self.plan["scenarios"]!.array {
            let dir = scenario["dir"]!.string
            let manifest = try PackManifest.parse(Data(contentsOf: Repo.golden("packs").appending(path: dir).appending(path: "manifest.json")))
            for fragment in manifest.fragments {
                let bytes = try Data(contentsOf: Repo.golden("packs").appending(path: dir).appending(path: fragment.file))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                if digest != fragment.sha256 || bytes.count != fragment.bytes {
                    let path = dir == "." ? fragment.file : "\(dir)/\(fragment.file)"
                    if !mismatched.contains(path) { mismatched.append(path) }
                }
            }
        }
        #expect(mismatched == ["negative/checksum-mismatch/f-beta.db.gz"])
    }

    @Test func theBundledCoreLoadsToTheBaseState() async throws {
        let harness = try await Harness()
        try await harness.expectState(Self.plan["baseState"]!.string, where: "base")
    }

    // MARK: - Scenarios

    @Test(arguments: scenarioNames)
    func scenario(_ name: String) async throws {
        let scenario = Self.plan["scenarios"]!.array.first { $0["name"]?.string == name }!
        let harness = try await Harness()

        // A step may be served from a release other than its scenario's: a
        // fragment republished between two installs.
        let scenarioRelease = try await harness.serve(scenario["dir"]!.string)

        for (index, step) in scenario["steps"]!.array.enumerated() {
            let op = step["op"]!.string
            let target = step["collection"]?.string ?? step["fragment"]?.string ?? ""
            let at = "\(name) step \(index + 1) (\(op) \(target))"
            let (release, service, manifest) = if let dir = step["dir"]?.string {
                try await harness.serve(dir)
            } else {
                scenarioRelease
            }
            await release.clearRequests()

            var thrown: (any Error)?
            do {
                switch op {
                case "install":
                    let collection = try #require(manifest.collection(target), "\(at): no such collection")
                    try await service.install(
                        collection,
                        from: manifest,
                        idSpace: step["appIdSpace"]?.int ?? Self.appIdSpace
                    )
                case "uninstall":
                    try await service.uninstall(target)
                case "markStale":
                    try await harness.database.write { db in
                        try db.execute(sql: "UPDATE installed_fragments SET sha256 = 'stale' WHERE id = ?", arguments: [target])
                    }
                default:
                    Issue.record("\(at): unknown op")
                }
            } catch {
                thrown = error
            }

            if let expectedError = step["throws"] {
                switch expectedError["type"]!.string {
                case "PackException":
                    let error = thrown as? PackError
                    #expect(error != nil, "\(at): expected a PackError, got \(String(describing: thrown))")
                    #expect(error?.message == expectedError["message"]?.string, "\(at)")
                case "DatabaseException":
                    // sqflite's DatabaseException in Flutter; GRDB's
                    // DatabaseError here. Matched by substring, as the Flutter
                    // test does, because each wraps SQLite's message its own way.
                    let error = thrown as? DatabaseError
                    #expect(error != nil, "\(at): expected a DatabaseError, got \(String(describing: thrown))")
                    let wanted = expectedError["messageContains"]!.string
                    #expect(error?.message?.contains(wanted) == true, "\(at): \(String(describing: error)) lacks \(wanted)")
                case let other:
                    Issue.record("\(at): unknown error type \(other)")
                }
            } else {
                #expect(thrown == nil, "\(at): should succeed, threw \(String(describing: thrown))")
            }

            if let downloads = step["downloads"] {
                #expect(await release.requests == downloads.array.map(\.string), "\(at): fragments fetched")
            }
            if let state = step["state"] {
                try await harness.expectState(state.string, where: at)
            }

            // Success or failure, nothing is left behind: no attached pack, no
            // archive or expanded database in the workspace.
            let attached = try await harness.database.writeWithoutTransaction { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_database_list")
            }
            #expect(!attached.contains("pack"), "\(at): pack left attached")
            let workspace = harness.workspace
            if FileManager.default.fileExists(atPath: workspace.path) {
                let left = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
                #expect(left.isEmpty, "\(at): temporary files left in the workspace: \(left)")
            }
        }
    }
}

// MARK: - Harness

/// A fresh core database, a workspace, and a way to serve releases.
private final class Harness: Sendable {
    let root: URL
    let database: DatabasePool
    var workspace: URL { PackService.workspace(in: root) }

    deinit { try? FileManager.default.removeItem(at: root) }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "council-pack-golden-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabasePool(path: root.appending(path: "core.db").path, configuration: Corpus.configuration())
        // The bundled core, then the bookkeeping Corpus.initialize adds.
        let baseSQL = try String(
            contentsOf: Repo.golden("packs").appending(path: PackGoldenTests.plan["baseSql"]!.string),
            encoding: .utf8
        )
        try await database.write { db in
            try db.execute(sql: baseSQL)
            try PackService.createTables(db)
        }
    }

    func serve(_ dir: String) async throws -> (FixtureRelease, PackService, PackManifest) {
        let release = FixtureRelease(dir: dir)
        let service = PackService(
            database: database,
            workspace: workspace,
            fetcher: release,
            manifestURL: release.manifestURL
        )
        return (release, service, try await service.fetchManifest())
    }

    func expectState(_ file: String, where at: String) async throws {
        let expected = PackGoldenTests.readJSON(file)
        let actual = try await dump(PackGoldenTests.tables)
        for table in PackGoldenTests.tables {
            let want = expected["tables"]?[table]
            let got = actual.tables[table]
            #expect(got?.columns == want?["columns"]?.array.map(\.string), "\(at): columns of \(table) differ from \(file)")
            #expect(got?.rows == want?["rows"]?.array.map(\.array), "\(at): table \(table) differs from \(file)")
        }
        var wantFTS: [String: [String: String]] = [:]
        for (doc, columns) in expected["fts"]?.members ?? [] {
            wantFTS[doc] = Dictionary(uniqueKeysWithValues: columns.members.map { ($0.key, $0.value.string) })
        }
        #expect(actual.fts == wantFTS, "\(at): the FTS index differs from \(file)")
        // And the index agrees with content_units — throws if it does not.
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO content_fts(content_fts) VALUES('integrity-check')")
        }
    }

    /// The view of the database tools/build_pack_goldens.py records: every
    /// table, ordered by all columns left to right, `installed_at` left out;
    /// and the FTS index read from the index itself (fts5vocab), so a missing
    /// or stale entry is a difference.
    func dump(_ tables: [String]) async throws -> (tables: [String: (columns: [String], rows: [[OrderedJSON]])], fts: [String: [String: String]]) {
        try await database.writeWithoutTransaction { db in
            var out: [String: (columns: [String], rows: [[OrderedJSON]])] = [:]
            for table in tables {
                let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table])
                    .filter { $0 != "installed_at" }
                let order = (1...columns.count).map(String.init).joined(separator: ", ")
                let rows = try Row.fetchAll(db, sql: "SELECT \(columns.joined(separator: ", ")) FROM \(table) ORDER BY \(order)")
                out[table] = (columns, rows.map { row in (0..<columns.count).map { Harness.jsonable(row[$0] as DatabaseValue) } })
            }

            try db.execute(sql: "CREATE VIRTUAL TABLE temp.golden_vocab USING fts5vocab(main, content_fts, instance)")
            defer { try? db.execute(sql: "DROP TABLE temp.golden_vocab") }
            var tokens: [String: [String: [String]]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT doc, col, term FROM temp.golden_vocab ORDER BY doc, col, offset") {
                let doc = String(row["doc"] as Int64)
                tokens[doc, default: [:]][row["col"] as String, default: []].append(row["term"] as String)
            }
            let fts = tokens.mapValues { $0.mapValues { $0.joined(separator: " ") } }
            return (out, fts)
        }
    }

    private static func jsonable(_ value: DatabaseValue) -> OrderedJSON {
        switch value.storage {
        case .null: .null
        case .int64(let n): .int(Int(n))
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .blob(let data): .object([("blob", .string(data.map { String(format: "%02x", $0) }.joined()))])
        }
    }
}

/// A scenario directory served as if it were the published release. Records
/// which fragment files were requested, in order.
private actor FixtureRelease: PackFetcher {
    let dir: String
    private(set) var requests: [String] = []

    init(dir: String) { self.dir = dir }

    nonisolated var manifestURL: URL { URL(string: "https://golden.invalid/\(dir)/manifest.json")! }

    func clearRequests() { requests.removeAll() }

    private func file(for url: URL) -> URL? {
        let name = url.lastPathComponent
        if name != "manifest.json" { requests.append(name) }
        let file = Repo.golden("packs").appending(path: dir).appending(path: name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func get(_ url: URL) async throws -> (status: Int, body: Data) {
        guard let file = file(for: url) else { return (404, Data()) }
        return (200, try Data(contentsOf: file))
    }

    func download(_ url: URL, to destination: URL, progress: @Sendable (Int) -> Void) async throws -> Int {
        guard let file = file(for: url) else { return 404 }
        let bytes = try Data(contentsOf: file)
        // In 1 KB chunks, as the Flutter test's MockClient streams them.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }
        var sent = 0
        while sent < bytes.count {
            let end = min(sent + 1024, bytes.count)
            try sink.write(contentsOf: bytes[sent..<end])
            sent = end
            progress(sent)
        }
        return 200
    }
}

// MARK: - Reading the fixtures

extension OrderedJSON {
    var int: Int {
        guard case .int(let n) = self else { fatalError("expected an int, got \(self)") }
        return n
    }

    var string: String {
        guard case .string(let s) = self else { fatalError("expected a string, got \(self)") }
        return s
    }

    var array: [OrderedJSON] {
        guard case .array(let items) = self else { fatalError("expected an array, got \(self)") }
        return items
    }

    var members: [(key: String, value: OrderedJSON)] {
        guard case .object(let members) = self else { fatalError("expected an object, got \(self)") }
        return members
    }

    var keys: [String] { members.map(\.key) }
}

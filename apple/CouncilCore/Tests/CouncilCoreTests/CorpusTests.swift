// Covers Corpus.swift and Gzip.swift, ported from the corpus half of
// lib/src/services/database_service.dart.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// Installing the bundled corpus from the real assets/theology.db.gz, and the
/// version stamp that decides when to install it again.
@Suite struct CorpusTests {
    let directory: URL
    let archive = Repo.asset(CorpusConstants.bundledArchiveName)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "council-corpus-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    var dbURL: URL { directory.appending(path: CorpusConstants.databaseFileName) }
    var stampURL: URL { directory.appending(path: CorpusConstants.stampFileName) }

    func stamp() throws -> String { try String(contentsOf: stampURL, encoding: .utf8) }

    /// A row that only exists in the installed copy, so a reinstall shows up as
    /// its disappearance.
    func markInstalledCopy() throws {
        let queue = try DatabaseQueue(path: dbURL.path, configuration: Corpus.configuration())
        try queue.write { try $0.execute(sql: "CREATE TABLE install_marker (x)") }
        try queue.close()
    }

    func installedCopyIsMarked() throws -> Bool {
        let queue = try DatabaseQueue(path: dbURL.path, configuration: Corpus.configuration())
        defer { try? queue.close() }
        return try queue.read { try $0.tableExists("install_marker") }
    }

    @Test func aFreshInstallCopiesTheCorpusAndStampsIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }

        // The directory does not exist yet; installing creates it.
        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .installed)
        #expect(try stamp() == "\(CorpusConstants.corpusVersion)")
        let header = try FileHandle(forReadingFrom: dbURL).read(upToCount: 16)
        #expect(header == Data("SQLite format 3\0".utf8))
        // Nothing left over from the copy.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == [CorpusConstants.databaseFileName, CorpusConstants.stampFileName].sorted())
    }

    @Test func aCurrentInstallIsReused() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive)
        try markInstalledCopy()

        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .reused)
        #expect(try installedCopyIsMarked(), "a current corpus, with its packs, must be left alone")
    }

    @Test func aNewCorpusVersionReplacesTheOldOne() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive, version: 15)
        try markInstalledCopy()

        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive, version: 16)
            == .reinstalled(previousVersion: 15))
        #expect(try !installedCopyIsMarked())
        #expect(try stamp() == "16")
    }

    @Test func aMissingOrUnreadableStampForcesAReinstall() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive)

        try FileManager.default.removeItem(at: stampURL)
        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .reinstalled(previousVersion: nil))

        try Data("sixteen".utf8).write(to: stampURL)
        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .reinstalled(previousVersion: nil))
        #expect(try stamp() == "\(CorpusConstants.corpusVersion)")
    }

    @Test func aStampWithoutADatabaseInstallsAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive)
        try FileManager.default.removeItem(at: dbURL)
        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .installed)
    }

    @Test func aStampWrittenByTheFlutterAppIsRead() throws {
        // Dart wrote `'$corpusVersion'` and read it with int.tryParse, which
        // ignores surrounding whitespace; a trailing newline must not cost the
        // reader their packs.
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive)
        try markInstalledCopy()
        try Data("\(CorpusConstants.corpusVersion)\n".utf8).write(to: stampURL)
        #expect(try Corpus.installIfNeeded(in: directory, bundledArchive: archive) == .reused)
        #expect(try installedCopyIsMarked())
    }

    @Test func aReinstallDiscardsTheOldDatabasesJournals() throws {
        // A -wal (or a hot -journal) that outlives its database is replayed
        // into whatever file next has that name.
        defer { try? FileManager.default.removeItem(at: directory) }
        try Corpus.installIfNeeded(in: directory, bundledArchive: archive, version: 15)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("left over from the old corpus".utf8).write(to: URL(filePath: dbURL.path + suffix))
        }

        try Corpus.installIfNeeded(in: directory, bundledArchive: archive, version: 16)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: dbURL.path + suffix), "\(suffix) survived")
        }
    }

    @Test func initializeOpensAWritablePoolWithFTS5AndBookkeeping() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let corpus = try Corpus.initialize(in: directory, bundledArchive: archive)
        #expect(corpus.databaseURL == dbURL)

        try await corpus.database.read { db in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 0)
            for table in ["installed_collections", "collection_fragments", "installed_fragments", "fragment_sources"] {
                #expect(try db.tableExists(table), "\(table) missing")
            }
            #expect(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('installed_fragments')")
                .contains("sha256"))

            // The system SQLite has FTS5, and the bundled index is readable by
            // it: a ranked MATCH joined back to the content, as search runs it.
            let hits = try Row.fetchAll(db, sql: """
                SELECT cu.id, fts.rank FROM content_fts fts
                JOIN content_units cu ON fts.rowid = cu.id
                WHERE content_fts MATCH ?
                ORDER BY fts.rank, cu.id
                LIMIT 5
                """, arguments: ["\"grace\"*"])
            #expect(hits.count == 5)
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM content_fts WHERE content_fts MATCH 'grace'")
            #expect((total ?? 0) > 0)
        }

        // The bundled index agrees with its content table, on this SQLite.
        try await corpus.database.write { db in
            try db.execute(sql: "INSERT INTO content_fts(content_fts, rank) VALUES('integrity-check', 1)")
        }

        // Opening twice is harmless: the bookkeeping DDL is idempotent.
        let again = try Corpus.initialize(in: directory, bundledArchive: archive)
        #expect(try await again.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM installed_fragments") } == 0)
    }
}

@Suite struct GzipTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "council-gzip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    @Test func expandsAFixtureFragmentToASQLiteDatabase() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appending(path: "f-alpha.db")
        try Gzip.decompress(Repo.golden("packs/f-alpha.db.gz"), to: out)
        let queue = try DatabaseQueue(path: out.path)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM content_units") } == 2)
    }

    @Test func aTruncatedArchiveIsRejected() throws {
        // The golden checksum-mismatch fragment: the first half of a real one.
        // Its checksum stops it before expansion in PackService, but expansion
        // must not quietly yield half a database either.
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(throws: GzipError.self) {
            try Gzip.decompress(
                Repo.golden("packs/negative/checksum-mismatch/f-beta.db.gz"),
                to: scratch.appending(path: "half.db")
            )
        }
    }

    @Test func notGzipAtAllIsRejected() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bogus = scratch.appending(path: "bogus.gz")
        try Data("this is not gzip".utf8).write(to: bogus)
        #expect(throws: GzipError.self) { try Gzip.decompress(bogus, to: scratch.appending(path: "out")) }

        let empty = scratch.appending(path: "empty.gz")
        try Data().write(to: empty)
        #expect(throws: GzipError.self) { try Gzip.decompress(empty, to: scratch.appending(path: "out")) }
    }

    @Test func concatenatedMembersExpandOneAfterAnother() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let member = try Data(contentsOf: Repo.golden("packs/f-alpha.db.gz"))
        let single = scratch.appending(path: "single")
        try Gzip.decompress(Repo.golden("packs/f-alpha.db.gz"), to: single)

        let doubled = scratch.appending(path: "doubled.gz")
        try (member + member).write(to: doubled)
        let out = scratch.appending(path: "doubled")
        try Gzip.decompress(doubled, to: out)
        let once = try Data(contentsOf: single)
        #expect(try Data(contentsOf: out) == once + once)
    }
}

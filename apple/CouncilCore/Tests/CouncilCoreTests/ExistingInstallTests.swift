// Covers Migration/ExistingInstall.swift: the evidence the onboarding gate
// uses for a reader who has been through setup without a visible
// `has_onboarded` flag.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

@Suite struct ExistingInstallTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "council-existing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var userDatabaseURL: URL { directory.appending(path: UserDatabase.fileName) }
    private var corpusURL: URL { directory.appending(path: CorpusConstants.databaseFileName) }

    @Test func anEmptyDirectoryIsANewReader() throws {
        #expect(!ExistingInstall.hasReaderData(in: directory))
        // Read-only: nothing is created by asking.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aMissingDirectoryIsANewReader() {
        #expect(!ExistingInstall.hasReaderData(in: directory.appending(path: "nowhere")))
    }

    /// Both apps create the file on first launch, before onboarding, so its
    /// existence alone says nothing.
    @Test func aFreshUserDatabaseIsNotEvidence() throws {
        _ = try UserDatabase.open(at: userDatabaseURL)
        #expect(!ExistingInstall.hasReaderData(in: directory))
    }

    @Test func aNoteIsEvidence() async throws {
        let database = try UserDatabase.open(at: userDatabaseURL)
        try await AnnotationStore(database: database).createNote(
            contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil, body: "Grace",
            sourceTitle: nil, unitTitle: nil, reference: nil)
        #expect(ExistingInstall.hasReaderData(in: directory))
    }

    @Test func aHighlightIsEvidence() async throws {
        let database = try UserDatabase.open(at: userDatabaseURL)
        try await AnnotationStore(database: database).addHighlight(
            contentUnitId: 1, charStart: 0, charEnd: 4, colour: "yellow", quote: "Love",
            sourceTitle: nil, unitTitle: nil, reference: nil)
        #expect(ExistingInstall.hasReaderData(in: directory))
    }

    @Test func aConversationIsEvidence() async throws {
        let database = try UserDatabase.open(at: userDatabaseURL)
        _ = try await ChatHistoryStore(database: database).createConversation()
        #expect(ExistingInstall.hasReaderData(in: directory))
    }

    /// The corpus with the pack bookkeeping but nothing installed: what a
    /// first launch leaves behind.
    @Test func aCorpusWithNoCollectionsIsNotEvidence() throws {
        let queue = try DatabaseQueue(path: corpusURL.path)
        try queue.write { try PackService.createTables($0) }
        #expect(!ExistingInstall.hasReaderData(in: directory))
    }

    @Test func aCorpusWithoutTheBookkeepingTablesIsNotEvidence() throws {
        let queue = try DatabaseQueue(path: corpusURL.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE sources (id INTEGER PRIMARY KEY)") }
        #expect(!ExistingInstall.hasReaderData(in: directory))
    }

    /// The Flutter corpus: sqflite's rollback journal.
    @Test func anInstalledCollectionIsEvidence() throws {
        let queue = try DatabaseQueue(path: corpusURL.path)
        try queue.write { db in
            try PackService.createTables(db)
            try Self.insertCollection(db)
        }
        #expect(ExistingInstall.hasReaderData(in: directory))
    }

    /// The native corpus: a WAL `DatabasePool`, read both while the pool is
    /// open and after it has closed and SQLite has tidied away the -wal and
    /// -shm files, which a read-only open has to cope without.
    @Test func anInstalledCollectionInAWALCorpusIsEvidence() throws {
        do {
            let pool = try DatabasePool(path: corpusURL.path)
            try pool.write { db in
                try PackService.createTables(db)
                try Self.insertCollection(db)
            }
            #expect(ExistingInstall.hasReaderData(in: directory))
        }
        #expect(ExistingInstall.hasReaderData(in: directory))
    }

    @Test func anUnreadableFileIsNotEvidence() throws {
        try Data("not a database".utf8).write(to: userDatabaseURL)
        #expect(!ExistingInstall.hasReaderData(in: directory))
    }

    private static func insertCollection(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO installed_collections (id, name, corpus_version, installed_at)
            VALUES ('creeds-and-confessions', 'Creeds & Confessions', 2, '2026-11-04T00:00:00.000')
            """)
    }
}

// Covers UserData/UserDatabase.swift, ported from
// lib/src/services/user_database.dart, with the cases of
// test/user_database_migration_test.dart and the ones that only matter once
// two apps share the file.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// Opening, creating and migrating `council_user.db`, on disk, against files
/// built the way sqflite builds them.
@Suite struct UserDatabaseTests {
    let directory: URL
    var url: URL { directory.appending(path: UserDatabase.fileName) }

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "council-user-db-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The schema exactly as the Dart `_create` leaves it in `sqlite_master`
    /// (its `'''` strings, indentation and all), recorded from a file sqflite
    /// created, so a drift in the Swift SQL shows up here.
    static let dartSchema: [String: String] = [
        "highlights": """
            CREATE TABLE highlights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content_unit_id INTEGER NOT NULL,
                    char_start INTEGER NOT NULL,
                    char_end INTEGER NOT NULL,
                    colour TEXT NOT NULL,
                    quote TEXT NOT NULL,
                    source_title TEXT,
                    unit_title TEXT,
                    reference TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                  )
            """,
        "idx_highlights_unit": "CREATE INDEX idx_highlights_unit ON highlights(content_unit_id)",
        "notes": """
            CREATE TABLE notes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content_unit_id INTEGER,
                    char_start INTEGER,
                    char_end INTEGER,
                    quote TEXT,
                    body TEXT NOT NULL,
                    source_title TEXT,
                    unit_title TEXT,
                    reference TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                  )
            """,
        "idx_notes_unit": "CREATE INDEX idx_notes_unit ON notes(content_unit_id)",
        "conversations": """
            CREATE TABLE conversations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    passage_unit_id INTEGER,
                    passage_quote TEXT,
                    passage_reference TEXT,
                    passage_source TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                  )
            """,
        "conversation_messages": """
            CREATE TABLE conversation_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id INTEGER NOT NULL,
                    seq INTEGER NOT NULL,
                    is_user INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    citations TEXT,
                    generated INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                  )
            """,
        "idx_messages_conversation":
            "CREATE INDEX idx_messages_conversation ON conversation_messages(conversation_id, seq)",
    ]

    /// Our tables and indices as `sqlite_master` holds them.
    static func schema(_ db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT name, sql FROM sqlite_master
            WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%'
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as String, $0["sql"] as String) })
    }

    /// A file opened the way sqflite opens one: a plain connection, no GRDB
    /// bookkeeping.
    func withRawFile<T>(_ body: (Database) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.writeWithoutTransaction(body)
    }

    /// A migrated file has every table and index of a new one, with the same
    /// SQL, except that `ALTER TABLE` has rewritten `conversation_messages`'
    /// definition (SQLite splices the new column into the stored text, in
    /// either app).
    static func expectMigrated(_ schema: [String: String],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Set(schema.keys) == Set(dartSchema.keys), sourceLocation: sourceLocation)
        for (name, sql) in dartSchema where name != "conversation_messages" {
            #expect(schema[name] == sql, "\(name)", sourceLocation: sourceLocation)
        }
        #expect(schema["conversation_messages"]?.contains("generated INTEGER NOT NULL DEFAULT 0") == true,
                sourceLocation: sourceLocation)
    }

    /// What a test checks about an open database, read in one go.
    struct Snapshot {
        let schema: [String: String]
        let userVersion: Int?
        let journalMode: String?
        let hasGRDBMigrations: Bool
    }

    static func snapshot(_ database: UserDatabase) throws -> Snapshot {
        try database.queue.read { db in
            Snapshot(schema: try schema(db),
                     userVersion: try Int.fetchOne(db, sql: "PRAGMA user_version"),
                     journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                     hasGRDBMigrations: try db.tableExists("grdb_migrations"))
        }
    }

    func userVersion() throws -> Int {
        try withRawFile { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? -1 }
    }

    /// The order `_create` runs its statements in.
    static let dartOrder = ["highlights", "idx_highlights_unit", "notes", "idx_notes_unit",
                            "conversations", "conversation_messages", "idx_messages_conversation"]

    /// A version 1 file: by default the Dart `_create` minus the `generated`
    /// column. `asTheDartTestBuildsIt` is instead the shape
    /// test/user_database_migration_test.dart calls "the schema as version 1
    /// shipped it": only `conversations`, `conversation_messages` and `notes`,
    /// with no indices.
    func createVersion1(asTheDartTestBuildsIt: Bool = false) throws {
        let names = asTheDartTestBuildsIt ? ["conversations", "conversation_messages", "notes"] : Self.dartOrder
        try withRawFile { db in
            for name in names {
                let sql = Self.dartSchema[name]!
                try db.execute(sql: sql.replacingOccurrences(of: "        generated INTEGER NOT NULL DEFAULT 0,\n", with: ""))
            }
            try db.execute(sql: "PRAGMA user_version = 1")
            let now = "2026-07-20T09:15:02.481233"
            try db.execute(sql: "INSERT INTO conversations (title, created_at, updated_at) VALUES (?, ?, ?)",
                           arguments: ["What is grace?", now, now])
            try db.execute(sql: """
                INSERT INTO conversation_messages (conversation_id, seq, is_user, text, created_at)
                VALUES (1, 0, 0, 'Augustine calls it prevenient.', ?)
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO notes (body, quote, created_at, updated_at) VALUES (?, ?, ?, ?)
                """, arguments: ["Written before the upgrade.", "We believe and confess…", now, now])
            if !asTheDartTestBuildsIt {
                try db.execute(sql: """
                    INSERT INTO highlights (content_unit_id, char_start, char_end, colour, quote,
                                            created_at, updated_at)
                    VALUES (23558, 0, 57, 'yellow', 'In the beginning', ?, ?)
                    """, arguments: [now, now])
            }
        }
    }

    @Test func aFreshFileGetsTheDartSchemaAtTheCurrentVersion() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // The directory doesn't exist yet: open creates it.
        let database = try UserDatabase.open(at: url)
        let snapshot = try Self.snapshot(database)
        #expect(snapshot.schema == Self.dartSchema)
        #expect(snapshot.userVersion == UserDatabase.schemaVersion)
        // No GRDB migrations table: sqflite would never know about it.
        #expect(!snapshot.hasGRDBMigrations)
        // Still a rollback-journal file, as sqflite leaves it.
        #expect(snapshot.journalMode == "delete")
        try database.queue.close()
    }

    @Test func inMemoryHasTheSameSchema() throws {
        let snapshot = try Self.snapshot(try UserDatabase.inMemory())
        #expect(snapshot.schema == Self.dartSchema)
        #expect(snapshot.userVersion == 2)
    }

    /// test/user_database_migration_test.dart: "a version 1 database keeps its
    /// contents and gains the new column".
    @Test func aVersion1FileKeepsItsRowsAndGainsTheColumn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createVersion1()

        let database = try UserDatabase.open(at: url)
        let snapshot = try Self.snapshot(database)
        #expect(snapshot.userVersion == 2)
        Self.expectMigrated(snapshot.schema)
        let (text, generated, title) = try await database.queue.read { db in
            let message = try Row.fetchOne(db, sql: "SELECT text, generated FROM conversation_messages")
            return (message?["text"] as String?, message?["generated"] as Int?,
                    try String.fetchOne(db, sql: "SELECT title FROM conversations"))
        }
        #expect(text == "Augustine calls it prevenient.")
        // An answer from before the column existed reads as not-generated, so
        // an old thread shows no caveat rather than one on the wrong message.
        #expect(generated == 0)
        #expect(title == "What is grace?")
        // The column is writable.
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation_messages (conversation_id, seq, is_user, text, generated, created_at)
                VALUES (1, 1, 0, 'x', 1, '2026-07-20T09:16:00.000')
                """)
        }

        let store = AnnotationStore(database: database)
        let note = try #require(try await store.allNotes().first)
        #expect(note.body == "Written before the upgrade.")
        #expect(note.quote == "We believe and confess…")
        #expect(note.createdAt == DartDateTime.date(from: "2026-07-20T09:15:02.481233"))
        #expect(try await store.highlights(forUnit: 23558).map(\.colour) == ["yellow"])
        try database.queue.close()

        // And it opens again, now as version 2, without change.
        let again = try UserDatabase.open(at: url)
        #expect(try await AnnotationStore(database: again).countNotes() == 1)
        try again.queue.close()
    }

    /// The version 1 test/user_database_migration_test.dart builds has no
    /// `highlights` table and no indices, and the Dart `_upgrade` adds none
    /// of them. Here what is missing is created with the Dart SQL.
    @Test func theDartTestsVersion1FileGetsWhatItLacks() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try createVersion1(asTheDartTestBuildsIt: true)

        let database = try UserDatabase.open(at: url)
        Self.expectMigrated(try Self.snapshot(database).schema)
        let store = AnnotationStore(database: database)
        #expect(try await store.countNotes() == 1)
        try await store.addHighlight(contentUnitId: 1, charStart: 0, charEnd: 5, colour: "yellow", quote: "In th",
                                     sourceTitle: nil, unitTitle: nil, reference: nil)
        #expect(try await store.highlights(forUnit: 1).count == 1)
        try database.queue.close()
    }

    @Test func aCurrentFileIsNotWrittenTo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try UserDatabase.open(at: url).queue.close()
        let before = try Data(contentsOf: url)

        try UserDatabase.open(at: url).queue.close()
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aNewerSchemaIsRefusedAndLeftUntouched() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try withRawFile { db in
            try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, mood TEXT)")
            try db.execute(sql: "INSERT INTO notes (body, mood) VALUES ('from the future', 'hopeful')")
            try db.execute(sql: "PRAGMA user_version = 3")
        }
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(throws: UserDatabase.OpenError.newerSchema(found: 3, supported: 2)) {
            try UserDatabase.open(at: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [UserDatabase.fileName])
        #expect(try userVersion() == 3)
    }

    @Test func refusalExplainsItself() {
        let error = UserDatabase.OpenError.newerSchema(found: 3, supported: 2)
        #expect(error.description.contains("schema version 3"))
        #expect(error.description.contains("left untouched"))
    }

    /// `user_version` 0 with the tables already there isn't a file either app
    /// made; sqflite's `onCreate` would fail on `CREATE TABLE` too.
    @Test func unversionedTablesAreRefused() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try withRawFile { db in
            try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        }
        let before = try Data(contentsOf: url)
        #expect(throws: UserDatabase.OpenError.unversionedTables(["notes"])) {
            try UserDatabase.open(at: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try userVersion() == 0)
    }

    /// A zero-byte file is an empty database to SQLite, so it is created in,
    /// as sqflite would.
    @Test func anEmptyFileIsCreatedIn() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let database = try UserDatabase.open(at: url)
        #expect(try Self.snapshot(database).schema == Self.dartSchema)
        try database.queue.close()
    }
}

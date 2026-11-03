// Port of lib/src/services/user_database.dart.

import Foundation
import GRDB
import Synchronization

/// Everything the reader writes: highlights, notes and conversations.
///
/// Deliberately *not* `theology.db`. That file is a shipped artefact: it is
/// deleted and reinstalled whenever the bundled corpus version changes, and
/// content packs merge into it. A note stored there would be destroyed by a
/// routine content update, which is the one thing a reader's own writing must
/// never suffer.
///
/// ## Shared with the Flutter app
///
/// The native app installs over the Flutter one and opens this same file in
/// place (apple/PLAN.md, Phase 7), so the schema is the Dart `_create`
/// verbatim, statement for statement, `conversations` and
/// `conversation_messages` included even though chat arrives in Phase 5: the
/// file has to be complete from the first open, or a file created here would
/// be missing tables the Flutter app expects.
///
/// sqflite tracks the schema with `PRAGMA user_version`, and this does the
/// same rather than using GRDB's `DatabaseMigrator`, which records migrations
/// in a table of its own and never reads `user_version`. A file created by
/// either app therefore opens in the other:
///
/// - `user_version` 0 and none of the tables: a new file; create everything
///   and set the version, in one transaction (as sqflite's `onCreate` does).
/// - 1: the v1→v2 upgrade, the `generated` column on `conversation_messages`.
/// - 2: current.
/// - newer than 2: written by a later build. Refused with
///   `OpenError.newerSchema` and left untouched: guessing at an unknown
///   schema is how a reader's notes get destroyed.
///
/// One change from the Dart: at versions 1 and 2, any of the tables or
/// indices that is missing is created with the same SQL. The Dart migration
/// test (test/user_database_migration_test.dart) describes the shipped v1 as
/// having no `highlights` table at all, which the Dart `_upgrade` never adds,
/// so such a file would fail on the first highlight in either app. A file
/// that has everything is never written to.
///
/// ## Why a `DatabaseQueue`
///
/// Unlike the corpus, this is a small file with short writes, and a pool
/// would switch it to WAL: `journal_mode` is persistent, so the Flutter app's
/// single rollback-journal file would become three, which the Phase 7 Mac
/// migration (a copy out of the old sandbox container) would then have to
/// treat as a unit. A queue leaves the journal mode as sqflite left it, and
/// serialising the reader's own reads and writes costs nothing noticeable.
/// One connection, opened once and shared, for the reason the Dart gives: two
/// handles to one file is how a locked database happens.
///
/// Opening is synchronous and touches the disk: call `open(at:)` off the main
/// actor. Every query after that goes through GRDB's async APIs.
public final class UserDatabase: Sendable {
    public static let fileName = "council_user.db"

    /// Bumped when the tables below change. `migrate` must then learn how to
    /// carry an existing file forward (this database is never reinstalled, so
    /// migration is the only path), and the Dart `UserDatabase` must change in
    /// step, or the two apps will refuse each other's files.
    public static let schemaVersion = 2

    /// Why a file could not be opened. The file is left exactly as it was.
    public enum OpenError: Error, Equatable, CustomStringConvertible {
        /// `user_version` is newer than this build understands.
        case newerSchema(found: Int, supported: Int)
        /// `user_version` is 0 (never set) but some of the tables exist, so
        /// it isn't a file either app created. sqflite would fail here too,
        /// creating a table that already exists.
        case unversionedTables([String])

        public var description: String {
            switch self {
            case let .newerSchema(found, supported):
                "\(UserDatabase.fileName) has schema version \(found); this build reads up to \(supported). "
                    + "It was written by a newer version of Council and has been left untouched."
            case let .unversionedTables(tables):
                "\(UserDatabase.fileName) has no schema version but already contains "
                    + "\(tables.joined(separator: ", ")); it has been left untouched."
            }
        }
    }

    /// The one connection. Internal: the stores in CouncilCore are the API.
    let queue: DatabaseQueue

    private let broadcaster: ChangeBroadcaster
    /// Keeps the commit observation behind `annotationChanges()` alive.
    private let observation: AnyDatabaseCancellable

    private init(queue: DatabaseQueue) {
        self.queue = queue
        let broadcaster = ChangeBroadcaster()
        self.broadcaster = broadcaster
        // One observation for the database's lifetime, started here (off the
        // main actor, like the open itself) because starting one blocks until
        // the writer is free; `annotationChanges()` then only registers a
        // listener. `onError` can only fire while resolving the tables at
        // start, and `migrate` has just made sure they exist.
        observation = DatabaseRegionObservation(tracking: Table("highlights"), Table("notes"))
            .start(in: queue, onError: { _ in }, onChange: { _ in broadcaster.broadcast() })
    }

    /// Open the user database at `url`, creating or migrating it.
    ///
    /// Creates the parent directory if needed: on a fresh install Application
    /// Support may not exist yet (Flutter's `getApplicationSupportDirectory`
    /// created it as a side effect).
    public static func open(at url: URL) throws -> UserDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration())
        do {
            try queue.write(migrate)
        } catch {
            try? queue.close()
            throw error
        }
        return UserDatabase(queue: queue)
    }

    /// A fresh database in memory, for tests and previews.
    public static func inMemory() throws -> UserDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try queue.write(migrate)
        return UserDatabase(queue: queue)
    }

    /// Foreign keys off, as under sqflite. Nothing here declares one, so this
    /// only keeps the two apps' connections configured alike.
    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        config.label = "UserDatabase"
        return config
    }

    /// Fires after every committed write to `highlights` or `notes`, from any
    /// code using this database. Coalesced (`bufferingNewest(1)`): a listener
    /// should re-read, not count.
    func annotationChanges() -> AsyncStream<Void> {
        broadcaster.stream()
    }

    // MARK: - Schema

    /// Bring the file to `schemaVersion`, inside the caller's transaction.
    static func migrate(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        switch version {
        case 0:
            let present = try schema.filter { $0.kind == "table" }.map(\.name)
                .filter { try db.tableExists($0) }
            guard present.isEmpty else { throw OpenError.unversionedTables(present) }
            for object in schema { try db.execute(sql: object.sql) }
        case 1, 2:
            try createMissing(db)
            if version < 2 {
                // Dart's `_upgrade`, `from < 2`. Existing assistant messages
                // default to 0, so an old thread simply shows no caveat rather
                // than one attached to the wrong message. Guarded, unlike the
                // Dart, because `createMissing` may just have created the table
                // with the column already in it.
                let columns = try db.columns(in: "conversation_messages").map(\.name)
                if !columns.contains("generated") {
                    try db.execute(sql: "ALTER TABLE conversation_messages "
                        + "ADD COLUMN generated INTEGER NOT NULL DEFAULT 0")
                }
            }
        default:
            throw OpenError.newerSchema(found: version, supported: schemaVersion)
        }
        if version != schemaVersion {
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
    }

    /// Any table or index of `schema` the file lacks, created with its own SQL.
    private static func createMissing(_ db: Database) throws {
        for object in schema {
            let exists = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = ? AND name = ?
                """, arguments: [object.kind, object.name]) ?? false
            if !exists { try db.execute(sql: object.sql) }
        }
    }

    /// The Dart `_create`, statement for statement and in its order, with its
    /// whitespace, so that `sqlite_master` reads the same whichever app made
    /// the file.
    static let schema: [(kind: String, name: String, sql: String)] = [
        // Highlights and notes are anchored by character offsets into a
        // content unit *and* carry the text they were taken from. The offsets
        // make rendering cheap; the text is what lets an annotation be re-found
        // if a corpus rebuild shifts the unit underneath it, and what lets a
        // note still show its quotation when the passage is gone entirely.
        ("table", "highlights", """
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
            """),
        ("index", "idx_highlights_unit", "CREATE INDEX idx_highlights_unit ON highlights(content_unit_id)"),
        ("table", "notes", """
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
            """),
        ("index", "idx_notes_unit", "CREATE INDEX idx_notes_unit ON notes(content_unit_id)"),
        ("table", "conversations", """
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
            """),
        // `generated` marks a message a language model actually wrote, as
        // opposed to one the app composed itself (a retrieval-only result, an
        // unavailable-backend notice, an error). Only the former needs the
        // reliability caveat, and only the first one in a thread carries it.
        ("table", "conversation_messages", """
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
            """),
        ("index", "idx_messages_conversation",
         "CREATE INDEX idx_messages_conversation ON conversation_messages(conversation_id, seq)"),
    ]
}

/// Fans one commit observation out to any number of `AsyncStream` listeners.
private final class ChangeBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func broadcast() {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield()
        }
    }
}

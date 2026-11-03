// Port of lib/src/services/annotation_service.dart.

import Foundation
import GRDB

/// A stretch of a passage the reader has marked.
public struct Highlight: Sendable, Hashable, Identifiable {
    public let id: Int
    public let contentUnitId: Int
    /// Offsets into the unit's `content`, in UTF-16 code units (Dart string
    /// indices), end exclusive.
    public let charStart: Int
    public let charEnd: Int
    /// A highlight colour id. Held as a string so the data layer carries no
    /// dependency on how colours are drawn.
    public let colour: String
    public let quote: String
    public let sourceTitle: String?
    public let unitTitle: String?
    public let reference: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: Int, contentUnitId: Int, charStart: Int, charEnd: Int, colour: String, quote: String,
                sourceTitle: String?, unitTitle: String?, reference: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.contentUnitId = contentUnitId
        self.charStart = charStart
        self.charEnd = charEnd
        self.colour = colour
        self.quote = quote
        self.sourceTitle = sourceTitle
        self.unitTitle = unitTitle
        self.reference = reference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this mark shares at least one character with `start..<end`.
    /// Touching ranges (one ends where the other starts) don't overlap.
    public func overlaps(_ start: Int, _ end: Int) -> Bool {
        charStart < end && start < charEnd
    }

    init(row: Row) {
        id = row.lenientInt("id") ?? 0
        contentUnitId = row.lenientInt("content_unit_id") ?? 0
        charStart = row.lenientInt("char_start") ?? 0
        charEnd = row.lenientInt("char_end") ?? 0
        colour = row.lenientString("colour") ?? ""
        quote = row.lenientString("quote") ?? ""
        sourceTitle = row.lenientString("source_title")
        unitTitle = row.lenientString("unit_title")
        reference = row.lenientString("reference")
        createdAt = AnnotationStore.date(row, "created_at")
        updatedAt = AnnotationStore.date(row, "updated_at")
    }
}

/// A passage the reader wanted to write about, and what they wrote.
///
/// `quote` and `body` are separate because they answer to different owners:
/// the quote is the corpus's words and must not be edited, the body is the
/// reader's. A note may also stand alone (`contentUnitId` nil), though nothing
/// in either app creates one that way yet.
public struct Note: Sendable, Hashable, Identifiable {
    public let id: Int
    public let contentUnitId: Int?
    public let charStart: Int?
    public let charEnd: Int?
    public let quote: String?
    public let body: String
    public let sourceTitle: String?
    public let unitTitle: String?
    public let reference: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: Int, contentUnitId: Int?, charStart: Int?, charEnd: Int?, quote: String?, body: String,
                sourceTitle: String?, unitTitle: String?, reference: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.contentUnitId = contentUnitId
        self.charStart = charStart
        self.charEnd = charEnd
        self.quote = quote
        self.body = body
        self.sourceTitle = sourceTitle
        self.unitTitle = unitTitle
        self.reference = reference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: Row) {
        id = row.lenientInt("id") ?? 0
        contentUnitId = row.lenientInt("content_unit_id")
        charStart = row.lenientInt("char_start")
        charEnd = row.lenientInt("char_end")
        quote = row.lenientString("quote")
        body = row.lenientString("body") ?? ""
        sourceTitle = row.lenientString("source_title")
        unitTitle = row.lenientString("unit_title")
        reference = row.lenientString("reference")
        createdAt = AnnotationStore.date(row, "created_at")
        updatedAt = AnnotationStore.date(row, "updated_at")
    }
}

/// Reads and writes the reader's highlights and notes.
///
/// Constructed freely wherever it is needed: it holds no state of its own, and
/// the connection and change notifications belong to the shared
/// `UserDatabase`, so two stores on one database see each other's writes.
///
/// Rows are decoded leniently, as `ContentUnitRow` is: a timestamp that
/// `DartDateTime` can't read becomes `Date.distantPast` instead of failing the
/// whole query. The Dart `fromRow` would throw there and take the entire
/// Notes screen with it; one damaged row should cost at most its date.
///
/// Every timestamp written is `DartDateTime.string(from: .now)`, the local
/// format the Flutter app writes, because both apps sort these tables by the
/// text of `created_at` / `updated_at`.
public struct AnnotationStore: Sendable {
    public let database: UserDatabase

    public init(database: UserDatabase) {
        self.database = database
    }

    private var queue: DatabaseQueue { database.queue }

    // MARK: - Highlights

    /// Every highlight on one passage, ordered by where it starts (then by id,
    /// so oldest first) so that later marks paint over earlier ones where they
    /// overlap.
    public func highlights(forUnit id: Int) async throws -> [Highlight] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM highlights WHERE content_unit_id = ? ORDER BY char_start, id
                """, arguments: [id]).map(Highlight.init(row:))
        }
    }

    /// `highlights(forUnit:)` for many units in one read, for the
    /// continuous-scroll reader, which lays out several passages at once.
    ///
    /// Every requested id has an entry, empty when the unit has no
    /// highlights, so a caller caching the result can tell "none" from "not
    /// loaded yet".
    public func highlights(forUnits ids: [Int]) async throws -> [Int: [Highlight]] {
        let unique = Array(Set(ids))
        return try await queue.read { db in
            var result = Dictionary(uniqueKeysWithValues: unique.map { ($0, [Highlight]()) })
            for chunk in unique.chunks(ofCount: SQLList.maxVariables) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM highlights WHERE content_unit_id IN (\(SQLList.marks(chunk.count)))
                    ORDER BY content_unit_id, char_start, id
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    let highlight = Highlight(row: row)
                    result[highlight.contentUnitId, default: []].append(highlight)
                }
            }
            return result
        }
    }

    /// Every highlight, most recent first.
    public func allHighlights(limit: Int = 500) async throws -> [Highlight] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM highlights ORDER BY created_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map(Highlight.init(row:))
        }
    }

    /// Mark `charStart..<charEnd` in `colour`, replacing whatever was already
    /// marked there.
    ///
    /// Overlapping marks are removed rather than layered. Two colours over one
    /// verse has no meaning the reader could act on, and leaving the old row
    /// behind would make "highlight, change your mind, highlight again" grow
    /// the database without ever changing what is on screen.
    ///
    /// The delete and the insert run in one transaction, which the Dart
    /// version does not do (it issues them as two statements): a failure
    /// between them there would erase the old highlight without writing the
    /// new one, and an observer could see the passage with neither.
    @discardableResult
    public func addHighlight(contentUnitId: Int, charStart: Int, charEnd: Int, colour: String, quote: String,
                             sourceTitle: String?, unitTitle: String?, reference: String?) async throws -> Highlight {
        let (stamp, now) = Self.now()
        return try await queue.write { db in
            try db.execute(sql: """
                DELETE FROM highlights WHERE content_unit_id = ? AND char_start < ? AND ? < char_end
                """, arguments: [contentUnitId, charEnd, charStart])
            try db.execute(sql: """
                INSERT INTO highlights (content_unit_id, char_start, char_end, colour, quote,
                                        source_title, unit_title, reference, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [contentUnitId, charStart, charEnd, colour, quote,
                                 sourceTitle, unitTitle, reference, stamp, stamp])
            return Highlight(id: Int(db.lastInsertedRowID), contentUnitId: contentUnitId,
                             charStart: charStart, charEnd: charEnd, colour: colour, quote: quote,
                             sourceTitle: sourceTitle, unitTitle: unitTitle, reference: reference,
                             createdAt: now, updatedAt: now)
        }
    }

    /// Clear any highlight touching `charStart..<charEnd`. Returns how many
    /// went.
    @discardableResult
    public func removeHighlights(inUnit id: Int, charStart: Int, charEnd: Int) async throws -> Int {
        try await queue.write { db in
            try db.execute(sql: """
                DELETE FROM highlights WHERE content_unit_id = ? AND char_start < ? AND ? < char_end
                """, arguments: [id, charEnd, charStart])
            return db.changesCount
        }
    }

    public func deleteHighlight(id: Int) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM highlights WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Notes

    /// Every note, most recent first: the order the Notes screen shows them
    /// in, and the only order it offers.
    ///
    /// Ordered by `updatedAt` rather than creation: a note the reader came back
    /// to and added a thought to is live again, and burying it under things
    /// merely created more recently would be wrong.
    public func allNotes(limit: Int = 1000) async throws -> [Note] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM notes ORDER BY updated_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map(Note.init(row:))
        }
    }

    /// The notes on one passage, most recently updated first, as `allNotes`.
    public func notes(forUnit id: Int) async throws -> [Note] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM notes WHERE content_unit_id = ? ORDER BY updated_at DESC, id DESC
                """, arguments: [id]).map(Note.init(row:))
        }
    }

    public func countNotes() async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
        }
    }

    /// One note, or nil if it has been deleted. Not in the Dart service (its
    /// note editor is handed the whole `Note`); here so an editor can re-read
    /// after `changes()` fires.
    public func note(id: Int) async throws -> Note? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ?", arguments: [id]).map(Note.init(row:))
        }
    }

    @discardableResult
    public func createNote(contentUnitId: Int?, charStart: Int?, charEnd: Int?, quote: String?, body: String = "",
                           sourceTitle: String?, unitTitle: String?, reference: String?) async throws -> Note {
        let (stamp, now) = Self.now()
        return try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes (content_unit_id, char_start, char_end, quote, body,
                                   source_title, unit_title, reference, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [contentUnitId, charStart, charEnd, quote, body,
                                 sourceTitle, unitTitle, reference, stamp, stamp])
            return Note(id: Int(db.lastInsertedRowID), contentUnitId: contentUnitId, charStart: charStart,
                        charEnd: charEnd, quote: quote, body: body, sourceTitle: sourceTitle,
                        unitTitle: unitTitle, reference: reference, createdAt: now, updatedAt: now)
        }
    }

    /// Replace a note's body and bump `updated_at`, which moves it to the top
    /// of `allNotes`.
    public func updateNoteBody(id: Int, body: String) async throws {
        let (stamp, _) = Self.now()
        try await queue.write { db in
            try db.execute(sql: "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?",
                           arguments: [body, stamp, id])
        }
    }

    public func deleteNote(id: Int) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Changes

    /// Fires after every committed write to highlights or notes, so screens
    /// showing the same passage can't drift apart.
    ///
    /// Backed by one GRDB `DatabaseRegionObservation` on the shared
    /// `UserDatabase`, so it also sees writes made through another
    /// `AnnotationStore`, or by any other code on that database, and stays
    /// silent for a write that changed nothing (a delete matching no row).
    /// The element carries no detail and bursts are coalesced to one pending
    /// element: re-read what you show. A write's notification is delivered
    /// before the write's `await` returns. The stream ends when the listening
    /// task is cancelled.
    public func changes() -> AsyncStream<Void> {
        database.annotationChanges()
    }

    // MARK: - Helpers

    /// The timestamp to store, and the `Date` it reads back as, so a value
    /// returned from a write is equal to the same row read later (SwiftUI
    /// diffing relies on that) despite the string's microsecond precision.
    private static func now() -> (String, Date) {
        let stamp = DartDateTime.string(from: Date())
        return (stamp, DartDateTime.date(from: stamp) ?? Date())
    }

    static func date(_ row: Row, _ column: String) -> Date {
        row.lenientString(column).flatMap { DartDateTime.date(from: $0) } ?? .distantPast
    }

}

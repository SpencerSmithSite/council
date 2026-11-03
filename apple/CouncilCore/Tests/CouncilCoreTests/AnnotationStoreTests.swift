// Covers UserData/AnnotationStore.swift. The highlight and note cases are
// test/annotation_service_test.dart's; the rest cover what the Swift store
// adds (batch reads, the transaction, change notifications) and reading rows
// the Flutter app wrote.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// Highlights and notes against a real SQLite, in memory, with the schema the
/// apps ship.
@Suite struct AnnotationStoreTests {
    let database: UserDatabase
    let store: AnnotationStore

    init() throws {
        database = try UserDatabase.inMemory()
        store = AnnotationStore(database: database)
    }

    @discardableResult
    func mark(_ start: Int, _ end: Int, _ colour: String, unit: Int = 23558) async throws -> Highlight {
        try await store.addHighlight(contentUnitId: unit, charStart: start, charEnd: end, colour: colour,
                                     quote: "In the beginning", sourceTitle: nil, unitTitle: "Genesis 1",
                                     reference: "Genesis 1:1")
    }

    // MARK: Highlights

    @Test func highlightsRoundTrip() async throws {
        let added = try await mark(0, 57, "yellow")
        let stored = try await store.highlights(forUnit: 23558)
        #expect(stored == [added], "what a write returns equals what a read returns, dates included")
        #expect(stored.first?.colour == "yellow")
        #expect(stored.first?.reference == "Genesis 1:1")
        #expect(stored.first?.sourceTitle == nil)
    }

    /// Two colours over one verse has no meaning the reader could act on, and
    /// leaving the old row would grow the file on every change of mind.
    @Test func recolouringReplacesRatherThanLayers() async throws {
        try await mark(0, 57, "yellow")
        try await mark(0, 57, "green")
        #expect(try await store.highlights(forUnit: 23558).map(\.colour) == ["green"])
    }

    @Test func anOverlappingMarkClearsWhatItCovers() async throws {
        try await mark(0, 57, "yellow")
        try await mark(40, 120, "blue")
        #expect(try await store.highlights(forUnit: 23558).map(\.charStart) == [40])
    }

    @Test func aMarkThatDoesNotOverlapIsLeftAlone() async throws {
        try await mark(0, 57, "yellow")
        // Touching at 57 is not overlapping: the range end is exclusive.
        try await mark(57, 160, "blue")
        #expect(try await store.highlights(forUnit: 23558).count == 2)
    }

    @Test func removalIsByRangeNotById() async throws {
        try await mark(0, 57, "yellow")
        #expect(try await store.removeHighlights(inUnit: 23558, charStart: 10, charEnd: 20) == 1)
        #expect(try await store.highlights(forUnit: 23558).isEmpty)
        #expect(try await store.removeHighlights(inUnit: 23558, charStart: 10, charEnd: 20) == 0)
    }

    @Test func highlightsAreScopedToTheirPassage() async throws {
        try await mark(0, 57, "yellow")
        #expect(try await store.highlights(forUnit: 99999).isEmpty)
        try await mark(0, 57, "blue", unit: 99999)
        #expect(try await store.highlights(forUnit: 23558).map(\.colour) == ["yellow"])
    }

    @Test func deleteHighlightById() async throws {
        let first = try await mark(0, 10, "yellow")
        try await mark(20, 30, "blue")
        try await store.deleteHighlight(id: first.id)
        #expect(try await store.highlights(forUnit: 23558).map(\.colour) == ["blue"])
    }

    @Test func overlapsMatchesTheSQL() {
        let highlight = Highlight(id: 1, contentUnitId: 1, charStart: 10, charEnd: 20, colour: "yellow",
                                  quote: "", sourceTitle: nil, unitTitle: nil, reference: nil,
                                  createdAt: .now, updatedAt: .now)
        #expect(highlight.overlaps(0, 11))
        #expect(highlight.overlaps(19, 30))
        #expect(highlight.overlaps(12, 14))
        #expect(highlight.overlaps(0, 100))
        #expect(!highlight.overlaps(0, 10))
        #expect(!highlight.overlaps(20, 30))
    }

    @Test func aPassageIsOrderedByStartThenAge() async throws {
        try await mark(50, 60, "blue")
        try await mark(0, 10, "yellow")
        try await mark(20, 30, "green")
        #expect(try await store.highlights(forUnit: 23558).map(\.charStart) == [0, 20, 50])
    }

    @Test func batchReadGroupsByUnitInTheSameOrder() async throws {
        try await mark(50, 60, "blue", unit: 1)
        try await mark(0, 10, "yellow", unit: 1)
        try await mark(5, 9, "green", unit: 2)
        let ids = Array(1...1200) // more than one statement's worth
        let grouped = try await store.highlights(forUnits: ids + [1])
        #expect(grouped.count == 1200, "every requested unit has an entry")
        #expect(grouped[1]?.map(\.charStart) == [0, 50])
        #expect(grouped[1] == (try await store.highlights(forUnit: 1)))
        #expect(grouped[2]?.map(\.colour) == ["green"])
        #expect(grouped[3] == [])
        #expect(try await store.highlights(forUnits: []).isEmpty)
    }

    @Test func allHighlightsIsNewestFirstAndLimited() async throws {
        // Written directly so the timestamps differ by more than the clock's
        // resolution; ties fall back to id, newest first.
        try await database.queue.write { db in
            for (index, stamp) in ["2026-09-01T12:00:00.000", "2026-09-03T12:00:00.000",
                                   "2026-09-02T12:00:00.000", "2026-09-03T12:00:00.000"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO highlights (content_unit_id, char_start, char_end, colour, quote,
                                            created_at, updated_at) VALUES (?, 0, 1, 'yellow', '', ?, ?)
                    """, arguments: [index + 1, stamp, stamp])
            }
        }
        #expect(try await store.allHighlights().map(\.contentUnitId) == [4, 2, 3, 1])
        #expect(try await store.allHighlights(limit: 2).map(\.contentUnitId) == [4, 2])
    }

    /// The delete and the insert are one transaction: if the insert fails,
    /// the highlight it would have replaced is still there.
    @Test func aFailedReplacementKeepsTheOldHighlight() async throws {
        try await mark(0, 57, "yellow")
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse BEFORE INSERT ON highlights
                WHEN NEW.colour = 'red' BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        await #expect(throws: DatabaseError.self) { try await mark(0, 57, "red") }
        #expect(try await store.highlights(forUnit: 23558).map(\.colour) == ["yellow"])
    }

    // MARK: Notes

    /// Coming back to an older note makes it live again; it shouldn't stay
    /// buried under something merely created more recently.
    @Test func notesAreNewestFirstByWhenTheyWereLastWrittenIn() async throws {
        let first = try await store.createNote(contentUnitId: 1, charStart: nil, charEnd: nil, quote: "a",
                                               body: "first", sourceTitle: nil, unitTitle: nil, reference: nil)
        try await store.createNote(contentUnitId: 2, charStart: nil, charEnd: nil, quote: "b",
                                   body: "second", sourceTitle: nil, unitTitle: nil, reference: nil)
        try await Task.sleep(for: .milliseconds(5))
        try await store.updateNoteBody(id: first.id, body: "first, revisited")

        #expect(try await store.allNotes().map(\.body) == ["first, revisited", "second"])
        let revisited = try #require(try await store.note(id: first.id))
        #expect(revisited.updatedAt > revisited.createdAt)
        #expect(revisited.createdAt == first.createdAt)
    }

    @Test func theQuotationSurvivesEditingTheBody() async throws {
        let note = try await store.createNote(contentUnitId: 546, charStart: 10, charEnd: 34,
                                              quote: "We believe and confess…", sourceTitle: "Belgic Confession",
                                              unitTitle: "Article 3", reference: "Of the Holy Scripture")
        #expect(note.body == "")
        try await store.updateNoteBody(id: note.id, body: "Compare with Trent.")

        let stored = try await store.notes(forUnit: 546)
        #expect(stored.count == 1)
        #expect(stored.first?.quote == "We believe and confess…")
        #expect(stored.first?.body == "Compare with Trent.")
        #expect(stored.first?.reference == "Of the Holy Scripture")
        #expect(stored.first?.charStart == 10)
        #expect(stored.first?.charEnd == 34)
    }

    @Test func deletingOneLeavesTheRest() async throws {
        let note = try await store.createNote(contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil,
                                              body: "gone", sourceTitle: nil, unitTitle: nil, reference: nil)
        try await store.createNote(contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil,
                                   body: "kept", sourceTitle: nil, unitTitle: nil, reference: nil)
        try await store.deleteNote(id: note.id)

        #expect(try await store.countNotes() == 1)
        #expect(try await store.allNotes().map(\.body) == ["kept"])
        #expect(try await store.note(id: note.id) == nil)
    }

    @Test func aCreatedNoteEqualsItsStoredRow() async throws {
        let note = try await store.createNote(contentUnitId: 7, charStart: 1, charEnd: 2, quote: "q",
                                              body: "b", sourceTitle: "s", unitTitle: "u", reference: "r")
        #expect(try await store.note(id: note.id) == note)
    }

    @Test func allNotesHonoursItsLimit() async throws {
        for index in 0..<5 {
            try await store.createNote(contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil,
                                       body: "\(index)", sourceTitle: nil, unitTitle: nil, reference: nil)
        }
        #expect(try await store.allNotes(limit: 3).count == 3)
        #expect(try await store.allNotes().count == 5)
    }

    // MARK: Interop

    /// Rows as the Flutter app writes them (microsecond and millisecond
    /// stamps, nulls), plus damage it never would: one bad date costs that
    /// date, not the list.
    @Test func readsRowsTheFlutterAppWrote() async throws {
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes (content_unit_id, char_start, char_end, quote, body, source_title,
                                   unit_title, reference, created_at, updated_at) VALUES
                (23558, 0, 57, 'In the beginning', 'Creation ex nihilo', 'KJV', 'Genesis 1', 'Genesis 1:1',
                 '2026-07-20T09:15:02.481233', '2026-07-21T18:00:00.000'),
                (NULL, NULL, NULL, NULL, 'standalone', NULL, NULL, NULL,
                 '2026-07-19T08:00:00.000', 'not a date')
                """)
        }
        // Ordered by the text of `updated_at`, as in Dart, so the damaged
        // value ("n" > "2") sorts first.
        let notes = try await store.allNotes()
        #expect(notes.map(\.body) == ["standalone", "Creation ex nihilo"])
        #expect(notes[0].contentUnitId == nil)
        #expect(notes[0].updatedAt == .distantPast)
        #expect(DartDateTime.string(from: notes[0].createdAt) == "2026-07-19T08:00:00.000")
        let written = notes[1]
        #expect(written.contentUnitId == 23558)
        #expect(written.reference == "Genesis 1:1")
        #expect(written.createdAt == DartDateTime.date(from: "2026-07-20T09:15:02.481233"))
        #expect(DartDateTime.string(from: written.updatedAt) == "2026-07-21T18:00:00.000")
    }

    @Test func writesTimestampsInTheDartLocalFormat() async throws {
        let highlight = try await mark(0, 5, "yellow")
        let stamp = try await database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT created_at FROM highlights WHERE id = ?", arguments: [highlight.id])
        }
        let text = try #require(stamp)
        // yyyy-MM-ddTHH:mm:ss.mmm[uuu], no zone designator.
        #expect(text.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}(\d{3})?/) != nil, "\(text)")
        #expect(DartDateTime.string(from: highlight.createdAt) == text)
    }

    // MARK: Changes

    @Test func everyWriteIsAnnounced() async throws {
        var changes = store.changes().makeAsyncIterator()
        // Another store on the same database sees the same notifications.
        var other = AnnotationStore(database: database).changes().makeAsyncIterator()

        let highlight = try await mark(0, 5, "yellow")
        #expect(await changes.next() != nil)
        #expect(await other.next() != nil)

        try await store.deleteHighlight(id: highlight.id)
        #expect(await changes.next() != nil)

        let note = try await store.createNote(contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil,
                                              body: "", sourceTitle: nil, unitTitle: nil, reference: nil)
        #expect(await changes.next() != nil)
        try await store.updateNoteBody(id: note.id, body: "x")
        #expect(await changes.next() != nil)
        try await store.deleteNote(id: note.id)
        #expect(await changes.next() != nil)
        try await mark(0, 5, "yellow")
        #expect(await changes.next() != nil)
        try await store.removeHighlights(inUnit: 23558, charStart: 0, charEnd: 5)
        #expect(await changes.next() != nil)
    }

    /// A burst of writes leaves one pending element, not one per write, and a
    /// write that changes nothing announces nothing.
    @Test func changesAreCoalescedAndOnlyForRealChanges() async throws {
        let stream = store.changes()
        try await mark(0, 5, "yellow")
        try await mark(10, 15, "yellow")
        try await mark(20, 25, "yellow")
        try await store.deleteNote(id: 12345)

        let received = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        received.cancel()
        #expect(await received.value == 1)
    }
}

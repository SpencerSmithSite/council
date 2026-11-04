// Covers UserData/ChatHistoryStore.swift. The cases of
// test/chat_history_service_test.dart, in its order, then what the Swift store
// adds: rows the Flutter app wrote, the stored JSON, retitling edge cases and
// change notifications.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

/// Conversations that outlive the app being closed, against a real SQLite in
/// memory with the schema the apps ship.
@Suite struct ChatHistoryStoreTests {
    let database: UserDatabase
    let history: ChatHistoryStore

    init() throws {
        database = try UserDatabase.inMemory()
        history = ChatHistoryStore(database: database)
    }

    @Test func messagesComeBackInTheOrderTheyWereSent() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "What is grace?")
        try await history.addMessage(conversationId: conversation.id, isUser: false, text: "Augustine says…")
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "And Aquinas?")

        let messages = try await history.messages(conversationId: conversation.id)
        #expect(messages.map(\.text) == ["What is grace?", "Augustine says…", "And Aquinas?"])
        #expect(messages.map(\.isUser) == [true, false, true])
    }

    /// An answer that comes back without its sources is the thing this app is
    /// trying not to be, so they are stored with the message.
    @Test func citationsSurviveTheRoundTrip() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: false, text: "Grace is prevenient [1].",
                                     citations: [Citation(contentId: 42, source: "On Grace and Free Will")])

        let stored = try #require(try await history.messages(conversationId: conversation.id).first)
        #expect(stored.citations.first?.source == "On Grace and Free Will")
        #expect(stored.citations.first?.contentId == 42)
    }

    /// The reliability caveat hangs off this: it belongs under an answer a
    /// model produced, not under a retrieval-only result or an error notice.
    @Test func aMessageRecordsWhetherAModelWroteIt() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: false, text: "Search-only mode is on…")
        try await history.addMessage(conversationId: conversation.id, isUser: false, text: "Augustine says…",
                                     generated: true)

        #expect(try await history.messages(conversationId: conversation.id).map(\.generated) == [false, true])
    }

    @Test func aMalformedCitationBlobCostsTheCitationsNotTheMessage() async throws {
        let conversation = try await history.createConversation()
        let id = try await history.addMessage(conversationId: conversation.id, isUser: false, text: "An answer.")
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE conversation_messages SET citations = 'not json' WHERE id = ?", arguments: [id])
        }

        let stored = try #require(try await history.messages(conversationId: conversation.id).first)
        #expect(stored.text == "An answer.")
        #expect(stored.citations.isEmpty)
    }

    /// One is created the moment a reader asks about a passage; going back
    /// without asking anything mustn't leave a thread behind.
    @Test func emptyConversationsStayOutOfTheHistoryList() async throws {
        try await history.createConversation()
        #expect(try await history.conversations().isEmpty)
    }

    @Test func theListIsOrderedByMostRecentActivity() async throws {
        let older = try await history.createConversation(title: "older")
        let newer = try await history.createConversation(title: "newer")
        try await history.addMessage(conversationId: older.id, isUser: true, text: "first")
        try await Task.sleep(for: .milliseconds(5))
        try await history.addMessage(conversationId: newer.id, isUser: true, text: "second")

        #expect(try await history.conversations().map(\.title) == ["newer", "older"])

        // Returning to the older thread lifts it back to the top.
        try await Task.sleep(for: .milliseconds(5))
        try await history.addMessage(conversationId: older.id, isUser: true, text: "again")
        #expect(try await history.conversations().first?.title == "older")
    }

    @Test func theListCarriesAPreviewAndACount() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "question")
        try await history.addMessage(conversationId: conversation.id, isUser: false, text: "answer")

        let listed = try #require(try await history.conversations().first)
        #expect(listed.messageCount == 2)
        #expect(listed.preview == "answer")
    }

    @Test func aThreadIsNamedAfterItsOpeningQuestionOnce() async throws {
        let conversation = try await history.createConversation()
        try await history.retitleIfUnnamed(conversationId: conversation.id, title: "What did Trent decree?")
        try await history.retitleIfUnnamed(conversationId: conversation.id, title: "Something else entirely")

        #expect(try await history.conversation(id: conversation.id)?.title == "What did Trent decree?")
    }

    @Test func aPassageAnchoredThreadRemembersItsPassage() async throws {
        let passage = PinnedPassage(contentUnitId: 23558,
                                    quote: "In the beginning God created the heaven and the earth.",
                                    reference: "Genesis 1:1", sourceTitle: "The Holy Bible: King James Version")
        let conversation = try await history.createConversation(title: "Genesis 1:1", passage: passage)

        let stored = try #require(try await history.conversation(id: conversation.id))
        #expect(stored.passage?.contentUnitId == 23558)
        #expect(stored.passage?.reference == "Genesis 1:1")
        #expect(stored.passage?.quote.hasPrefix("In the beginning") == true)
        #expect(stored.passage == passage)
    }

    @Test func deletingAConversationTakesItsMessagesWithIt() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "hello")
        try await history.deleteConversation(id: conversation.id)

        #expect(try await history.conversation(id: conversation.id) == nil)
        #expect(try await history.messages(conversationId: conversation.id).isEmpty)
    }

    @Test func deleteIfEmptySparesAThreadThatWasUsed() async throws {
        let used = try await history.createConversation()
        try await history.addMessage(conversationId: used.id, isUser: true, text: "hello")
        let unused = try await history.createConversation()

        try await history.deleteIfEmpty(id: used.id)
        try await history.deleteIfEmpty(id: unused.id)

        #expect(try await history.conversation(id: used.id) != nil)
        #expect(try await history.conversation(id: unused.id) == nil)
    }

    // MARK: - The Swift store

    @Test func whatAWriteReturnsEqualsWhatAReadReturns() async throws {
        let created = try await history.createConversation(title: "T")
        #expect(try await history.conversation(id: created.id) == created)
    }

    /// Byte for byte what Dart's `jsonEncode` writes, empty citations as NULL,
    /// sequence numbers from 0, and the conversation touched.
    @Test func rowsAreWrittenAsTheFlutterAppWritesThem() async throws {
        let conversation = try await history.createConversation()
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "q")
        try await history.addMessage(
            conversationId: conversation.id, isUser: false, text: "a",
            citations: [Citation(contentId: 7, source: "Didache", author: nil, tradition: "Early Church",
                                 sourceURL: "https://x/y")],
            generated: true)
        struct Stored: Sendable { let seq, isUser, generated: Int; let citations: String?; let createdAt: String? }
        let rows = try await database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversation_messages ORDER BY seq").map {
                Stored(seq: $0["seq"], isUser: $0["is_user"], generated: $0["generated"], citations: $0["citations"],
                       createdAt: $0["created_at"])
            }
        }
        #expect(rows.map(\.seq) == [0, 1])
        #expect(rows.map(\.isUser) == [1, 0])
        #expect(rows.map(\.generated) == [0, 1])
        #expect(rows[0].citations == nil)
        #expect(rows[1].citations == #"[{"contentId":7,"source":"Didache","author":null,"#
            + #""tradition":"Early Church","sourceUrl":"https://x/y"}]"#)
        let stamp = try #require(rows[1].createdAt)
        #expect(DartDateTime.date(from: stamp) != nil, "a Dart local ISO timestamp")
        let touched = try await history.conversation(id: conversation.id)
        #expect(touched?.updatedAt ?? .distantPast > conversation.updatedAt)
    }

    /// A thread written by the Flutter app: its timestamps, its citation JSON
    /// (as `jsonEncode` wrote it, keys and nulls and all), and one row whose
    /// date doesn't parse, which costs only that date.
    @Test func rowsTheFlutterAppWroteReadBack() async throws {
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, passage_unit_id, passage_quote, passage_reference,
                                           passage_source, created_at, updated_at)
                VALUES (5, 'Genesis 1:1', 23558, 'In the beginning', 'Genesis 1:1', NULL,
                        '2026-10-30T09:15:02.123456', '2026-10-30T09:16:40.000001')
                """)
            try db.execute(sql: """
                INSERT INTO conversation_messages (conversation_id, seq, is_user, text, citations, generated, created_at)
                VALUES (5, 0, 1, 'What does this mean?', NULL, 0, '2026-10-30T09:15:02.200000'),
                       (5, 1, 0, 'It means [1].', '[{"contentId":23558,"source":"Genesis 1:1","author":null,"tradition":null,"sourceUrl":null}]', 1, 'garbage')
                """)
        }
        let listed = try #require(try await history.conversations().first)
        #expect(listed.id == 5)
        #expect(listed.messageCount == 2)
        #expect(listed.preview == "It means [1].")
        #expect(listed.passage == PinnedPassage(contentUnitId: 23558, quote: "In the beginning",
                                                reference: "Genesis 1:1", sourceTitle: nil))
        #expect(listed.createdAt == DartDateTime.date(from: "2026-10-30T09:15:02.123456"))

        let messages = try await history.messages(conversationId: 5)
        #expect(messages.map(\.text) == ["What does this mean?", "It means [1]."])
        #expect(messages[1].citations == [Citation(contentId: 23558, source: "Genesis 1:1")])
        #expect(messages[1].generated)
        #expect(messages[1].createdAt == .distantPast)
    }

    /// Dart orders by `seq, id`, so two rows with one `seq` (possible when
    /// two writers raced in the Dart code) keep insertion order.
    @Test func equalSequenceNumbersFallBackToInsertionOrder() async throws {
        let conversation = try await history.createConversation()
        try await database.queue.write { db in
            for text in ["b", "a"] {
                try db.execute(sql: """
                    INSERT INTO conversation_messages (conversation_id, seq, is_user, text, created_at)
                    VALUES (?, 0, 1, ?, '2026-10-30T09:15:02.000000')
                    """, arguments: [conversation.id, text])
            }
        }
        #expect(try await history.messages(conversationId: conversation.id).map(\.text) == ["b", "a"])
    }

    @Test func listingRespectsTheLimitAndBreaksTiesByNewestId() async throws {
        try await database.queue.write { db in
            for id in 1...3 {
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, ?, '2026-10-30T09:00:00.000000', '2026-10-30T09:00:00.000000')
                    """, arguments: [id, "t\(id)"])
                try db.execute(sql: """
                    INSERT INTO conversation_messages (conversation_id, seq, is_user, text, created_at)
                    VALUES (?, 0, 1, 'x', '2026-10-30T09:00:00.000000')
                    """, arguments: [id])
            }
        }
        #expect(try await history.conversations().map(\.id) == [3, 2, 1])
        #expect(try await history.conversations(limit: 2).map(\.id) == [3, 2])
    }

    @Test func updatingAMessageReplacesTextAndCitations() async throws {
        let conversation = try await history.createConversation()
        let id = try await history.addMessage(conversationId: conversation.id, isUser: false, text: "draft",
                                              citations: [Citation(contentId: 1, source: "S")])
        try await history.updateMessage(id: id, text: "final")
        let stored = try #require(try await history.messages(conversationId: conversation.id).first)
        #expect(stored.text == "final")
        #expect(stored.citations.isEmpty, "citations default to none, stored as NULL, as in Dart")
    }

    @Test(arguments: [
        ("  What   did\tTrent\n\ndecree?  ", "What did Trent decree?"),
        ("\u{85}Question\u{85}", "Question"),  // trimmed by trim(), though \s doesn't match it
        ("a\u{85}\u{85}b", "a\u{85}\u{85}b"),  // and not collapsed in the middle
        ("a\u{A0}\u{3000}b", "a b"),
        (String(repeating: "x", count: 80), String(repeating: "x", count: 80)),
        (String(repeating: "x", count: 81), String(repeating: "x", count: 80) + "…"),
        (String(repeating: "x", count: 78) + "𝔊", String(repeating: "x", count: 78) + "𝔊"),
        (String(repeating: "x", count: 79) + "𝔊y", String(repeating: "x", count: 79) + "\u{FFFD}…"),
    ])
    func retitlingCleansTheQuestionAsDartDoes(_ question: String, _ expected: String) {
        #expect(DartText.equal(ChatHistoryStore.cleanTitle(question), expected))
    }

    @Test func aBlankQuestionLeavesTheTitleAlone() async throws {
        let conversation = try await history.createConversation()
        try await history.retitleIfUnnamed(conversationId: conversation.id, title: " \n\t ")
        #expect(try await history.conversation(id: conversation.id)?.title == ChatHistoryStore.untitled)
    }

    @Test func aPinnedPassageLabelsItselfForTheModel() {
        #expect(PinnedPassage(contentUnitId: 1, quote: "", reference: "John 3:16", sourceTitle: "KJV").promptLabel
            == "KJV — John 3:16")
        #expect(PinnedPassage(contentUnitId: 1, quote: "", reference: "Book I").promptLabel == "Book I")
        #expect(PinnedPassage(contentUnitId: 1, quote: "", reference: "", sourceTitle: "").promptLabel == "")
    }

    @Test func changesFireForConversationWritesAndNotForAnnotations() async throws {
        let changes = history.changes()
        var iterator = changes.makeAsyncIterator()
        let conversation = try await history.createConversation()
        await iterator.next()
        try await history.addMessage(conversationId: conversation.id, isUser: true, text: "q")
        await iterator.next()

        try await history.deleteConversation(id: conversation.id)
        await iterator.next()

        let annotationChanges = AnnotationStore(database: database).changes()
        var annotationIterator = annotationChanges.makeAsyncIterator()
        let quiet = history.changes()
        try await AnnotationStore(database: database).createNote(
            contentUnitId: 1, charStart: nil, charEnd: nil, quote: nil, sourceTitle: nil, unitTitle: nil,
            reference: nil)
        await annotationIterator.next()
        // The note produced no conversation change: nothing is pending.
        let pending = Task {
            var quietIterator = quiet.makeAsyncIterator()
            return await quietIterator.next()
        }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        #expect(await pending.value == nil)
    }
}

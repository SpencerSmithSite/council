// Port of lib/src/services/chat_history_service.dart. The cases in
// test/chat_history_service_test.dart are ChatHistoryStoreTests.

import Foundation
import GRDB

/// A passage a conversation is anchored to.
///
/// Set when the reader selected text and asked about it, so that reopening the
/// conversation weeks later still shows what was being discussed: a thread of
/// "what does this mean?" with the "this" missing is not resumable.
public struct PinnedPassage: Sendable, Hashable {
    public let contentUnitId: Int
    /// The selected text, as the reader saw it.
    public let quote: String
    /// "Genesis 1:1", or empty when the selection has no reference.
    public let reference: String
    public let sourceTitle: String?

    public init(contentUnitId: Int, quote: String, reference: String, sourceTitle: String? = nil) {
        self.contentUnitId = contentUnitId
        self.quote = quote
        self.reference = reference
        self.sourceTitle = sourceTitle
    }

    /// How the passage is described to the model: "title — reference",
    /// leaving out whichever is missing or empty.
    public var promptLabel: String {
        var parts: [String] = []
        if let sourceTitle, !sourceTitle.isEmpty { parts.append(sourceTitle) }
        if !reference.isEmpty { parts.append(reference) }
        return parts.joined(separator: " — ")
    }
}

/// One thread with the model.
public struct Conversation: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let passage: PinnedPassage?
    public let createdAt: Date
    /// When the last message was added: the history list's order.
    public let updatedAt: Date
    /// Filled in only by `ChatHistoryStore.conversations(limit:)`, which is
    /// the only place that needs them: the list shows both and would otherwise
    /// run a query per row. Zero and nil elsewhere.
    public let messageCount: Int
    /// The newest message's text, for the list.
    public let preview: String?

    public init(id: Int, title: String, passage: PinnedPassage?, createdAt: Date, updatedAt: Date,
                messageCount: Int = 0, preview: String? = nil) {
        self.id = id
        self.title = title
        self.passage = passage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.preview = preview
    }

    init(row: Row) {
        let unitId = row.lenientInt("passage_unit_id")
        self.init(
            id: row.lenientInt("id") ?? 0,
            title: row.lenientString("title") ?? "",
            passage: unitId.map {
                PinnedPassage(contentUnitId: $0,
                              quote: row.lenientString("passage_quote") ?? "",
                              reference: row.lenientString("passage_reference") ?? "",
                              sourceTitle: row.lenientString("passage_source"))
            },
            createdAt: AnnotationStore.date(row, "created_at"),
            updatedAt: AnnotationStore.date(row, "updated_at"),
            messageCount: row.lenientInt("message_count") ?? 0,
            preview: row.lenientString("preview"))
    }
}

/// One turn, stored with the citations it was answered from.
///
/// The citations are kept as JSON rather than as rows of their own. They are
/// only ever read back with their message, never queried across, and a passage
/// can be removed from the corpus by a pack change, at which point a foreign
/// key would either block the delete or take the answer's provenance with it.
public struct StoredMessage: Sendable, Hashable, Identifiable {
    public let id: Int
    public let isUser: Bool
    public let text: String
    public let citations: [Citation]
    /// True when a language model wrote this, rather than the app itself.
    ///
    /// Drives the once-per-thread reliability caveat: a retrieval-only result
    /// or an error notice is the app speaking and needs no such warning, and
    /// attaching one there would train the reader to ignore it. The caveat
    /// goes under the first message in a thread with this set, derived from
    /// the transcript rather than tracked, so it lands in the same place when
    /// the thread is reopened.
    public let generated: Bool
    public let createdAt: Date

    public init(id: Int, isUser: Bool, text: String, citations: [Citation] = [], generated: Bool = false,
                createdAt: Date) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.citations = citations
        self.generated = generated
        self.createdAt = createdAt
    }

    /// A malformed citation blob costs the citations on one message; it must
    /// not cost the reader their conversation.
    init(row: Row) {
        let raw = row.lenientString("citations")
        self.init(
            id: row.lenientInt("id") ?? 0,
            isUser: row.lenientInt("is_user") == 1,
            text: row.lenientString("text") ?? "",
            citations: raw.flatMap { $0.isEmpty ? nil : Citation.decode(jsonText: $0) } ?? [],
            generated: (row.lenientInt("generated") ?? 0) == 1,
            createdAt: AnnotationStore.date(row, "created_at"))
    }
}

/// Conversations with the model, kept so they can be returned to.
///
/// Over the shared `UserDatabase`, in the tables the Flutter app created and
/// with its SQL, so threads started in either app open in the other. Like
/// `AnnotationStore`, it holds no state of its own and can be constructed
/// wherever it is needed; every method is async and runs off the caller's
/// actor.
///
/// Rows are decoded leniently: a timestamp `DartDateTime` can't read becomes
/// `Date.distantPast`, where the Dart `fromRow` would throw and lose the whole
/// list. Timestamps written are `DartDateTime.string(from: .now)`, the local
/// format the Flutter app writes, because the list is sorted by the text of
/// `updated_at`.
///
/// How the chat screen uses it (as Flutter's does):
/// - Create the conversation on the first question, not when the screen
///   opens, so glancing at Ask and leaving doesn't litter the history. Title
///   it after the pinned passage's reference when there is one; otherwise
///   create it as "New conversation" and `retitleIfUnnamed` with the question.
/// - Add the question as soon as it is sent; add the answer once, when it is
///   finished (see `Generation.Outcome`), against the conversation it was
///   asked in, not whichever is on screen by then.
/// - On leaving a thread for a new one, `deleteIfEmpty` the old one.
public struct ChatHistoryStore: Sendable {
    /// What a conversation is called until it is named after its question.
    public static let untitled = "New conversation"

    public let database: UserDatabase

    public init(database: UserDatabase) {
        self.database = database
    }

    private var queue: DatabaseQueue { database.queue }

    /// Conversations, most recently active first, each with its message count
    /// and the newest message as a preview.
    ///
    /// Empty conversations are left out. One is created the moment a reader
    /// asks about a passage, and if they change their mind and go back, the
    /// history should not fill up with threads that were never had.
    public func conversations(limit: Int = 200) async throws -> [Conversation] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*,
                       (SELECT COUNT(*) FROM conversation_messages m
                         WHERE m.conversation_id = c.id) AS message_count,
                       (SELECT m.text FROM conversation_messages m
                         WHERE m.conversation_id = c.id
                         ORDER BY m.seq DESC LIMIT 1) AS preview
                FROM conversations c
                WHERE message_count > 0
                ORDER BY c.updated_at DESC, c.id DESC
                LIMIT ?
                """, arguments: [limit]).map(Conversation.init(row:))
        }
    }

    /// One conversation, without its count or preview; nil if it is gone.
    public func conversation(id: Int) async throws -> Conversation? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ? LIMIT 1", arguments: [id])
                .map(Conversation.init(row:))
        }
    }

    @discardableResult
    public func createConversation(title: String = untitled, passage: PinnedPassage? = nil) async throws
        -> Conversation
    {
        let (stamp, now) = Self.now()
        return try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (title, passage_unit_id, passage_quote, passage_reference,
                                           passage_source, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [title, passage?.contentUnitId, passage?.quote, passage?.reference,
                                 passage?.sourceTitle, stamp, stamp])
            return Conversation(id: Int(db.lastInsertedRowID), title: title, passage: passage,
                                createdAt: now, updatedAt: now)
        }
    }

    /// A conversation's messages in the order they were sent.
    public func messages(conversationId: Int) async throws -> [StoredMessage] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM conversation_messages WHERE conversation_id = ? ORDER BY seq, id
                """, arguments: [conversationId]).map(StoredMessage.init(row:))
        }
    }

    /// Append a turn, and mark the conversation as active (which moves it to
    /// the top of `conversations`). Returns the new message's id.
    ///
    /// Empty `citations` are stored as NULL, as in Dart. The sequence number
    /// is one past the conversation's highest, and the read, the insert and
    /// the touch run in one transaction, where Dart issues three statements: a
    /// second writer between them could otherwise take the same `seq`.
    @discardableResult
    public func addMessage(conversationId: Int, isUser: Bool, text: String, citations: [Citation] = [],
                           generated: Bool = false) async throws -> Int {
        let (stamp, _) = Self.now()
        return try await queue.write { db in
            let highest = try Int.fetchOne(db, sql: """
                SELECT MAX(seq) FROM conversation_messages WHERE conversation_id = ?
                """, arguments: [conversationId])
            try db.execute(sql: """
                INSERT INTO conversation_messages (conversation_id, seq, is_user, text, citations, generated,
                                                   created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [conversationId, (highest ?? -1) + 1, isUser ? 1 : 0, text,
                                 citations.isEmpty ? nil : Citation.jsonText(citations),
                                 generated ? 1 : 0, stamp])
            let id = Int(db.lastInsertedRowID)
            try Self.touch(db, conversationId, stamp)
            return id
        }
    }

    /// Replace a message's text and citations. Touches the conversation only
    /// when `conversationId` is given, as in Dart.
    public func updateMessage(id: Int, text: String, citations: [Citation] = [], conversationId: Int? = nil)
        async throws
    {
        let (stamp, _) = Self.now()
        try await queue.write { db in
            try db.execute(sql: "UPDATE conversation_messages SET text = ?, citations = ? WHERE id = ?",
                           arguments: [text, citations.isEmpty ? nil : Citation.jsonText(citations), id])
            if let conversationId { try Self.touch(db, conversationId, stamp) }
        }
    }

    /// Name a conversation after its opening question.
    ///
    /// Only takes effect while the conversation is still called
    /// `untitled`, so a title the reader has been shown doesn't change under
    /// them as the thread goes on. Runs of whitespace become one space (Dart's
    /// `\s+`), the ends are trimmed (Dart's `trim`, whose set adds U+0085),
    /// and anything over 80 UTF-16 code units is cut there and given an
    /// ellipsis. A question that is all whitespace changes nothing.
    public func retitleIfUnnamed(conversationId: Int, title: String) async throws {
        let clean = Self.cleanTitle(title)
        guard !clean.isEmpty else { return }
        try await queue.write { db in
            try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ? AND title = ?",
                           arguments: [clean, conversationId, Self.untitled])
        }
    }

    /// Delete a conversation and its messages, in one transaction.
    public func deleteConversation(id: Int) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM conversation_messages WHERE conversation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
        }
    }

    /// Discard a conversation that was opened and never used.
    public func deleteIfEmpty(id: Int) async throws {
        try await queue.write { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM conversation_messages WHERE conversation_id = ?
                """, arguments: [id]) ?? 0
            if count == 0 {
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Fires after every committed write to the conversation tables, from any
    /// code using this database, so the history list stays current while the
    /// chat screen writes. Coalesced like `AnnotationStore.changes()`: re-read,
    /// don't count. Ends when the listening task is cancelled.
    public func changes() -> AsyncStream<Void> {
        database.conversationChanges()
    }

    // MARK: - Helpers

    /// The title `retitleIfUnnamed` would store for `title`.
    static func cleanTitle(_ title: String) -> String {
        // `replaceAll(RegExp(r'\s+'), ' ')`, over code units as a Dart RegExp
        // without the unicode flag reads its input.
        var collapsed: [UInt16] = []
        var inRun = false
        for unit in title.utf16 {
            if DartText.isRegExpWhitespace(unit) {
                if !inRun { collapsed.append(0x20) }
                inRun = true
            } else {
                collapsed.append(unit)
                inRun = false
            }
        }
        let bounds = DartText.trimmedBounds(collapsed, 0..<collapsed.count)
        let clean = Array(collapsed[bounds])
        if clean.count > 80 { return String(decoding: clean[..<80], as: UTF16.self) + "…" }
        return String(decoding: clean, as: UTF16.self)
    }

    private static func touch(_ db: Database, _ conversationId: Int, _ stamp: String) throws {
        try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?", arguments: [stamp, conversationId])
    }

    private static func now() -> (String, Date) {
        let stamp = DartDateTime.string(from: Date())
        return (stamp, DartDateTime.date(from: stamp) ?? Date())
    }
}

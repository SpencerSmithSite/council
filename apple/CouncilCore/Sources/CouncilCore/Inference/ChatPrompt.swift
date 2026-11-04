// Port of lib/src/services/inference/chat_prompt.dart (`ChatPrompt`, which is
// the prompt building that used to live in the chat screen's `_streamAnswer`
// and `_pinnedAsPassage`) and of `buildSystemPrompt` in
// lib/src/services/ollama_service.dart.
//
// Golden: shared/golden/prompts/prompts.json (ChatPromptGoldenTests), written
// and verified by test/chat_prompt_golden_test.dart.

/// What is sent to a backend for one question: the system prompt, the prompt
/// with the retrieved sources in it, and the citations those sources become.
///
/// ```swift
/// let rows = try await retrieval.searchForRAG(question, limit: 6)
/// guard let built = ChatPrompt(question: question, retrieved: rows, pinned: passage,
///                              contextBudgetChars: backend.contextBudgetChars)
/// else { /* ChatText.noResults */ return }
/// let generation = Generation(backend.generate(prompt: built.prompt, system: built.system))
/// ```
///
/// Built exactly as the Flutter app builds it, character for character, so a
/// model answers the same question the same way in either app and a
/// conversation carried across (Phase 7) has the same citations:
///
/// - The pinned passage, when there is one, leads as source [1], ahead of
///   anything retrieval found. The reader is asking about *that* text, so it is
///   the source the answer has to be about; the rest is context to interpret
///   it. A sentence before the question says so, because without it the model
///   is handed several sources of equal standing and answers about the topic
///   rather than about the text in front of the person asking.
/// - Each passage gets an equal share of the backend's context budget,
///   `floor(budget / count)` clamped to 400...8000 characters. An on-device
///   model and a cloud model differ by an order of magnitude here, so one
///   fixed size would be wrong for almost all of them.
/// - A passage over its share is cut at that many UTF-16 code units (Dart's
///   `substring`), right-trimmed with Dart's whitespace set, and marked
///   `… [truncated]`. A cut through a surrogate pair leaves half a character:
///   Dart keeps the lone surrogate in its string, every backend then receives
///   it UTF-8 encoded as U+FFFD, and Swift (whose strings can't hold one)
///   produces U+FFFD directly. So the prompts agree on the wire, which is what
///   the golden fixture records.
public struct ChatPrompt: Sendable, Hashable {
    /// The system prompt every backend is given.
    public let system: String
    /// The sources, the anchor sentence when a passage is pinned, the question
    /// and the closing instruction.
    public let prompt: String
    /// One per source, in prompt order: `citations[0]` is source [1].
    public let citations: [Citation]

    /// The system prompt, verbatim from Dart's `buildSystemPrompt`.
    public static let systemPrompt = """
        You are a theological research assistant. Your role is to provide accurate, well-sourced \
        answers about Christian theology, drawing from historical sources including Church Fathers, \
        councils, and confessions of faith.

        Guidelines:
        - Always cite your sources using [1], [2], etc.
        - Present multiple traditions fairly when relevant
        - Distinguish between historical teaching and personal interpretation
        - Be precise about dates and attributions
        - If uncertain or the sources don't address the question, say so
        - Keep responses focused and relevant to the question
        """

    /// The prompt for `question`, or nil when there is nothing to build it
    /// from (no pinned passage and nothing retrieved). The chat screen then
    /// says `ChatText.noResults` instead of asking a model to answer from
    /// nothing.
    ///
    /// `retrieved` is `Retrieval.searchForRAG`'s result, in its order.
    /// `question` is used as given; the chat screen trims what was typed
    /// before asking, as Flutter's does.
    public init?(question: String, retrieved: [ContentUnitRow], pinned: PinnedPassage?, contextBudgetChars: Int) {
        let passages = Self.passages(retrieved: retrieved, pinned: pinned)
        guard !passages.isEmpty else { return nil }
        system = Self.systemPrompt
        citations = passages.map(\.citation)
        prompt = Self.prompt(question: question, passages: passages, anchor: pinned,
                             perPassage: Self.perPassageBudget(contextBudgetChars: contextBudgetChars,
                                                               passageCount: passages.count))
    }

    /// The citations an answer to these sources carries, without building a
    /// prompt: what search-only mode shows in place of an answer.
    public static func citations(retrieved: [ContentUnitRow], pinned: PinnedPassage?) -> [Citation] {
        passages(retrieved: retrieved, pinned: pinned).map(\.citation)
    }

    /// Each passage's share of the context budget, in UTF-16 code units:
    /// `(budget / count).floor().clamp(400, 8000)`.
    public static func perPassageBudget(contextBudgetChars: Int, passageCount: Int) -> Int {
        precondition(passageCount > 0, "a prompt needs at least one passage")
        // Floor division; Swift's `/` truncates, which differs only below zero.
        let share = contextBudgetChars >= 0
            ? contextBudgetChars / passageCount
            : -((-contextBudgetChars + passageCount - 1) / passageCount)
        return min(max(share, 400), 8000)
    }

    // MARK: - Building

    /// A source as the prompt sees it: the fields of Dart's passage map.
    struct Passage: Sendable {
        let id: Int
        let content: String
        let sourceTitle: String?
        let sourceAuthor: String?
        let tradition: String?
        let sourceURL: String?

        /// `p['source_title'] as String? ?? 'Unknown source'` and the rest.
        var citation: Citation {
            Citation(contentId: id, source: sourceTitle ?? "Unknown source", author: sourceAuthor,
                     tradition: tradition, sourceURL: sourceURL)
        }
    }

    static func passages(retrieved: [ContentUnitRow], pinned: PinnedPassage?) -> [Passage] {
        var passages: [Passage] = []
        if let pinned { passages.append(pinnedAsPassage(pinned)) }
        for row in retrieved {
            passages.append(Passage(id: row.id, content: row.content, sourceTitle: row.sourceTitle,
                                    sourceAuthor: row.sourceAuthor, tradition: row.tradition,
                                    sourceURL: row.sourceURL))
        }
        return passages
    }

    /// The selected passage shaped like a retrieved one, so it travels through
    /// the same prompt and citation code as everything else.
    ///
    /// It carries no source URL, which is not an oversight: the citation reads
    /// a missing URL as "origin not recorded", and for a passage quoted out of
    /// the reader's own screen that is exactly right. The traceable thing is
    /// the unit it came from, which the citation links to.
    static func pinnedAsPassage(_ pinned: PinnedPassage) -> Passage {
        Passage(id: pinned.contentUnitId, content: pinned.quote,
                sourceTitle: pinned.sourceTitle ?? pinned.reference,
                sourceAuthor: nil, tradition: nil, sourceURL: nil)
    }

    static func prompt(question: String, passages: [Passage], anchor: PinnedPassage?, perPassage: Int) -> String {
        // `StringBuffer.writeln` is the text then "\n".
        var context = "Relevant sources:\n\n"
        for (index, passage) in passages.enumerated() {
            context += "[\(index + 1)] \(passage.citation.promptLabel)\n"
            context += truncated(passage.content, to: perPassage) + "\n"
            context += "\n"
        }
        let anchorSentence = anchor.map {
            "The reader is reading \($0.promptLabel), quoted as source [1], and their question is about it. "
                + "Answer about that passage first, using the other sources to illuminate it.\n\n"
        } ?? ""
        return "\(context)\n\(anchorSentence)User question: \(question)\n\n"
            + "Answer using the provided sources. Cite them as [1], [2] and so on."
    }

    /// `content.length > n ? '${content.substring(0, n).trimRight()}… [truncated]' : content`,
    /// in UTF-16 code units.
    static func truncated(_ content: String, to limit: Int) -> String {
        let units = Array(content.utf16)
        guard units.count > limit else { return content }
        var end = limit
        while end > 0 && DartText.isTrimWhitespace(units[end - 1]) { end -= 1 }
        return String(decoding: units[..<end], as: UTF16.self) + "… [truncated]"
    }
}

/// The sentences the chat screen composes itself, rather than a model, worded
/// as the Flutter chat screen words them.
///
/// None of these is "generated": stored with `generated` false, so the
/// reliability caveat (which belongs under the first answer a model actually
/// wrote) is never attached to them.
public enum ChatText {
    /// Retrieval found nothing and no passage is pinned.
    public static let noResults =
        "I couldn't find anything in the library for that. Try different wording, or browse by tradition."

    /// Search-only mode: the retrieved passages are the answer, shown as this
    /// message's citations.
    public static func searchOnly(passageCount: Int) -> String {
        "Search-only mode is on, so no answer is generated. These \(passageCount) passages matched your question:"
    }

    /// `checkStatus()` said unavailable without saying why.
    public static let backendUnavailable = "That backend is unavailable."

    /// A stream that ended without a token: a provider that returned nothing,
    /// or a model that emitted only reasoning the filter then stripped. An
    /// empty bubble reads as an answer still on its way, so the reader is owed
    /// a sentence about it. Stored as the answer, `generated` true.
    public static let emptyAnswer =
        "The model returned an empty answer. Ask again, or choose a different backend in Settings."

    /// Appended to an answer the reader stopped (Markdown italics).
    public static let stoppedSuffix = "\n\n_(stopped)_"

    /// Turns any failure into something a reader can act on: Dart's
    /// `_friendlyError`.
    ///
    /// A dropped or refused connection almost always means the model was still
    /// loading when the request went out (Ollama's own retry is exhausted by
    /// the time this sees it), so it says that rather than surfacing a socket
    /// error. Everything else is "Error: " and the error's message, which for
    /// an `InferenceError` is already worded for the reader.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? InferenceError { return "Error: \(error.message)" }
        if TransportFailure.isConnectionDrop(error) {
            return "The model didn't respond in time — it may still be loading. Give it a moment and ask again."
        }
        return "Error: \(error.localizedDescription)"
    }
}

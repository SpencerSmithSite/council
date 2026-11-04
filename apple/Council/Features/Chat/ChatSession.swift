import CouncilCore
import Foundation
import Observation
import os

/// One Ask tab's conversation: the transcript on screen, the thread it is
/// stored as, the pinned passage, and the answer in flight.
///
/// The state and send flow of `ChatScreenState` in
/// lib/src/screens/chat_screen.dart, kept apart from `ChatView` so the view is
/// only layout. The order of `send` is Flutter's `_sendMessage` /
/// `_streamAnswer` step for step; the streaming itself is CouncilCore's
/// `Generation`, which is where the Dart screen's three stream bugs were
/// fixed (see its doc comment).
///
/// Every method takes the `AppModel` it works against instead of holding
/// one, because the view creates this as `@State`, before the environment is
/// readable.
///
/// ## The epoch
///
/// Starting a new thread or opening an older one while an answer is on its
/// way replaces the transcript under it. Each of those bumps `epoch`; a send
/// remembers the epoch it started in and, once it has changed, stops touching
/// the screen. What it produces is still stored, against the conversation the
/// question was asked in (Flutter's `_persistMessage(thread, …)`), so an
/// answer abandoned mid-stream is there when the reader goes back. Flutter
/// guarded only the streamed answer this way; here the "nothing found" and
/// "backend unavailable" replies are guarded too, since they also arrive
/// after awaits during which the reader may have moved on.
@Observable @MainActor
final class ChatSession {
    /// A message as the transcript shows it (Flutter's `ChatMessage`).
    struct Message: Identifiable, Equatable {
        let id = UUID()
        var text: String
        let isUser: Bool
        var citations: [Citation]
        /// Written by a language model rather than by the app; carries the
        /// reliability caveat when it is the first such message in the thread.
        let generated: Bool

        init(text: String, isUser: Bool, citations: [Citation] = [], generated: Bool = false) {
            self.text = text
            self.isUser = isUser
            self.citations = citations
            self.generated = generated
        }

        init(stored: StoredMessage) {
            self.init(text: stored.text, isUser: stored.isUser, citations: stored.citations,
                      generated: stored.generated)
        }
    }

    private(set) var messages: [Message] = []
    /// The stored thread being written to. Nil until the first question: the
    /// thread is created then, so glancing at Ask and leaving doesn't litter
    /// the history.
    private(set) var conversation: Conversation?
    /// The passage this thread is about: from the reader's Ask, or restored
    /// with a conversation from the history.
    private(set) var passage: PinnedPassage?
    /// A question is being answered: Send is Stop, and another can't be sent.
    private(set) var isLoading = false

    /// Collections that would have helped with the latest question and
    /// aren't installed, best first. Shown above the composer rather than in
    /// the answer, so it reads as a note about the library, not as something
    /// the sources say.
    private(set) var gaps: [PackSuggestion] = []
    /// The question the gaps are about, so it can be answered again once the
    /// missing collection arrives. Telling someone their answer was thin and
    /// then making them retype the question is most of a feature.
    private(set) var gapQuestion: String?
    /// Stop was pressed and the answer is winding down.
    private(set) var isStopping = false

    /// Moves when the transcript should go to its end whatever the reader was
    /// looking at: a question sent, a thread opened (Flutter's
    /// `_scrollToBottom(force: true)`).
    private(set) var jumpToEnd = 0
    /// Moves with each piece of a streaming answer and each reply the app
    /// adds; the view follows only if the reader is still at the end.
    private(set) var grew = 0

    /// The answer bubble being streamed into, if any.
    private(set) var streamingMessageID: Message.ID?

    private var generation: Generation?
    private var epoch = 0

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Chat")

    /// Which message carries the "a model wrote this" caveat: the first in
    /// the thread a model actually wrote. Derived rather than tracked, so it
    /// lands in the same place when the thread is reopened weeks later
    /// (Flutter's `_disclaimerIndex`).
    var caveatMessageID: Message.ID? {
        messages.first { !$0.isUser && $0.generated }?.id
    }

    // MARK: - Sending

    /// Asks `question`: Flutter's `_sendMessage`, then `_streamAnswer`.
    func send(_ question: String, app: AppModel) async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Read once, up front: a settings change mid-answer applies to the
        // next question, not to this one halfway through.
        let backend = app.inference.backend
        let history = app.chatHistory
        let pinned = passage
        let epoch = epoch

        messages.append(Message(text: text, isUser: true))
        isLoading = true
        isStopping = false
        jumpToEnd += 1
        defer {
            if self.epoch == epoch {
                isLoading = false
                isStopping = false
            }
        }

        // Worked out before retrieval runs, from the question rather than its
        // results: the point is to describe sources that are *absent*, which
        // by definition can't appear in what was retrieved (Flutter's
        // `_sendMessage`).
        gaps = app.packLibrary.coverageGaps(for: text, tags: QueryShaping.extractTags(text))
        gapQuestion = gaps.isEmpty ? nil : text

        let thread = await ensureConversation(firstQuestion: text, pinned: pinned, history: history, epoch: epoch)
        await store(Message(text: text, isUser: true), in: thread, history: history)

        do {
            guard let retrieval = app.retrieval else {
                throw InferenceError("The library is still being prepared. Ask again in a moment.")
            }
            let retrieved = try await retrieval.searchForRAG(text, limit: 6)

            // The pinned passage leads, ahead of anything retrieval found
            // (`ChatPrompt`).
            let citations = ChatPrompt.citations(retrieved: retrieved, pinned: pinned)
            guard !citations.isEmpty else {
                await reply(ChatText.noResults, in: thread, history: history, epoch: epoch)
                return
            }

            // Search-only mode: the retrieved passages are the answer.
            if backend.id == .none {
                await reply(ChatText.searchOnly(passageCount: citations.count), citations: citations,
                            in: thread, history: history, epoch: epoch)
                return
            }

            let status = await backend.checkStatus()
            guard status.available else {
                await reply(status.detail ?? ChatText.backendUnavailable, in: thread, history: history, epoch: epoch)
                return
            }
            // Stop pressed while the library was searched: nothing has been
            // asked of a model yet, so there is nothing to keep.
            guard !isStopping, self.epoch == epoch else { return }

            guard let prompt = ChatPrompt(question: text, retrieved: retrieved, pinned: pinned,
                                          contextBudgetChars: backend.contextBudgetChars) else {
                await reply(ChatText.noResults, in: thread, history: history, epoch: epoch)
                return
            }
            await stream(prompt, from: backend, in: thread, history: history, epoch: epoch)
        } catch is CancellationError {
            return
        } catch {
            await reply(ChatText.describe(error), in: thread, history: history, epoch: epoch)
        }
    }

    /// Streams the answer into a bubble of its own, then stores it once, as
    /// `Generation.Outcome` says (Flutter's `_streamAnswer`).
    private func stream(_ prompt: ChatPrompt, from backend: any InferenceBackend, in thread: Conversation?,
                        history: ChatHistoryStore?, epoch: Int) async {
        let index = messages.count
        let bubble = Message(text: "", isUser: false, citations: prompt.citations, generated: true)
        messages.append(bubble)
        streamingMessageID = bubble.id
        grew += 1
        defer { if streamingMessageID == bubble.id { streamingMessageID = nil } }

        // The reasoning filter on every backend: the downloaded model leaves
        // Qwen 3's `<think>` blocks in its output for the screen to remove,
        // and on the backends that already filter (Ollama) a second pass
        // finds nothing to take out.
        let generation = Generation(ReasoningFilter.strip(backend.generate(prompt: prompt.prompt,
                                                                           system: prompt.system)))
        self.generation = generation

        /// Whether the bubble this answer is written into is still on screen.
        func stillOurs() -> Bool { self.epoch == epoch && index < messages.count }

        for await text in generation.updates where stillOurs() {
            messages[index].text = text
            grew += 1
        }
        let outcome = await generation.outcome
        if self.generation === generation { self.generation = nil }

        let answer = outcome.answerText
        if stillOurs() {
            if let answer {
                messages[index].text = answer
            } else {
                // Failed or stopped before a word arrived: no empty bubble
                // carrying citations above the notice.
                messages.remove(at: index)
            }
            grew += 1
        }
        // Once, now that it is final, rather than a write per piece.
        if outcome.persistsAnswer, let answer {
            await store(Message(text: answer, isUser: false, citations: prompt.citations, generated: true),
                        in: thread, history: history)
        }
        if let notice = outcome.notice {
            await reply(notice, in: thread, history: history, epoch: epoch)
        }
    }

    /// Ends the answer in flight now, keeping what has arrived. While the
    /// library is still being searched, the question is abandoned before a
    /// model is asked.
    func stop() {
        guard isLoading, !isStopping else { return }
        isStopping = true
        generation?.stop()
    }

    // MARK: - Threads

    /// A fresh thread, keeping the old one in the history (Flutter's
    /// `startNewConversation`). Whatever is streaming belongs to the thread
    /// being left, so it is stopped first; the epoch keeps anything still on
    /// its way off the new transcript.
    func startNewConversation(app: AppModel) async {
        let previous = conversation
        reset()
        conversation = nil
        passage = nil
        if let previous {
            try? await app.chatHistory?.deleteIfEmpty(id: previous.id)
        }
    }

    /// Pins `passage` in a new thread: the reader's Ask. Flutter pushes a
    /// fresh chat screen for it; here the Ask tab starts a new thread, which
    /// leaves the one on screen in the history.
    func pin(_ passage: PinnedPassage, app: AppModel) async {
        await startNewConversation(app: app)
        self.passage = passage
    }

    /// Unpins the passage, so later questions in this sitting are asked
    /// without it. A thread already started about it keeps it in the
    /// history, and shows it again when reopened.
    func unpin() {
        passage = nil
    }

    /// Shows a stored thread to continue it (Flutter's `openConversation`).
    /// Opening the thread already on screen changes nothing, rather than
    /// stopping its answer and reloading it.
    func open(conversationID id: Int, app: AppModel) async {
        guard id != conversation?.id, let history = app.chatHistory else { return }
        do {
            guard let found = try await history.conversation(id: id) else { return }
            let stored = try await history.messages(conversationId: id)
            let previous = conversation
            reset()
            conversation = found
            passage = found.passage
            messages = stored.map(Message.init(stored:))
            jumpToEnd += 1
            if let previous { try? await history.deleteIfEmpty(id: previous.id) }
        } catch {
            Self.logger.error("Couldn't open conversation \(id): \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops what is in flight and clears the transcript for another one.
    private func reset() {
        generation?.stop()
        generation = nil
        streamingMessageID = nil
        epoch += 1
        messages = []
        isLoading = false
        isStopping = false
        gaps = []
        gapQuestion = nil
    }

    /// The missing collection has been installed: drop the notice and ask
    /// the question that prompted it again, now that the library holds what
    /// it lacked.
    func answerAgainAfterInstall(app: AppModel) async {
        let question = gapQuestion
        gaps = []
        gapQuestion = nil
        if let question { await send(question, app: app) }
    }

    // MARK: - Storing

    /// The thread to write to, created if this is its first question
    /// (Flutter's `_ensureConversation`). Named after the pinned passage's
    /// reference when there is one, so threads about different verses can be
    /// told apart in the list; otherwise after the question.
    ///
    /// Nil when there is no user database: the question is still answered,
    /// just not kept.
    private func ensureConversation(firstQuestion: String, pinned: PinnedPassage?, history: ChatHistoryStore?,
                                    epoch: Int) async -> Conversation? {
        if let conversation { return conversation }
        guard let history else { return nil }
        do {
            let title = pinned.map(\.reference).flatMap { $0.isEmpty ? nil : $0 } ?? ChatHistoryStore.untitled
            let created = try await history.createConversation(title: title, passage: pinned)
            if pinned == nil {
                try await history.retitleIfUnnamed(conversationId: created.id, title: firstQuestion)
            }
            // The title as stored, for the navigation subtitle.
            let current = try await history.conversation(id: created.id) ?? created
            if self.epoch == epoch { conversation = current }
            return current
        } catch {
            Self.logger.error("Couldn't start a conversation: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A reply the app writes itself (not generated): on screen if the reader
    /// is still in that thread, and stored in it either way.
    private func reply(_ text: String, citations: [Citation] = [], in thread: Conversation?,
                       history: ChatHistoryStore?, epoch: Int) async {
        let message = Message(text: text, isUser: false, citations: citations)
        if self.epoch == epoch {
            messages.append(message)
            grew += 1
        }
        await store(message, in: thread, history: history)
    }

    /// Stores `message` against `thread`, named explicitly rather than read
    /// from state (Flutter's `_persistMessage`).
    private func store(_ message: Message, in thread: Conversation?, history: ChatHistoryStore?) async {
        guard let thread, let history, !message.text.isEmpty else { return }
        do {
            try await history.addMessage(conversationId: thread.id, isUser: message.isUser, text: message.text,
                                         citations: message.citations, generated: message.generated)
        } catch {
            Self.logger.error("Couldn't store a message: \(String(describing: error), privacy: .public)")
        }
    }
}

// Covers Inference/Generation.swift. The three failures of
// test/chat_streaming_test.dart (Stop on a silent stream, an error before the
// first token, a new thread mid-answer), then the rest of the outcomes and the
// stall limit, with a backend the test drives by hand.

import Foundation
import Testing
@testable import CouncilCore

/// A backend's stream the test feeds, and a signal for when the consumer let
/// go of it.
struct ScriptedStream {
    let stream: AsyncThrowingStream<String, any Error>
    let continuation: AsyncThrowingStream<String, any Error>.Continuation
    let terminated: AsyncStream<Void>

    init() {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let (terminated, signal) = AsyncStream<Void>.makeStream()
        continuation.onTermination = { _ in
            signal.yield()
            signal.finish()
        }
        self.stream = stream
        self.continuation = continuation
        self.terminated = terminated
    }

    /// Waits until the consumer has terminated the stream.
    func waitForTermination() async {
        for await _ in terminated { return }
    }
}

@Suite(.timeLimit(.minutes(1))) struct GenerationTests {
    /// Waits for the generation to have taken in `text`.
    func waitFor(_ text: String, in generation: Generation) async {
        for await update in generation.updates where update == text { return }
    }

    // MARK: The Flutter screen's three failures

    /// Before, Stop set a flag read between chunks, so a backend that went
    /// quiet left the screen locked for the life of the app.
    @Test func stopEndsAnAnswerThatHasGoneQuiet() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.yield("Baptism is")
        await waitFor("Baptism is", in: generation)

        // The backend now says nothing further and never closes the stream.
        generation.stop()
        let outcome = await generation.outcome
        #expect(outcome == .stopped("Baptism is"))
        #expect(outcome.answerText == "Baptism is\n\n_(stopped)_", "what arrived before stopping is kept")
        #expect(outcome.persistsAnswer)
        #expect(outcome.notice == nil)
        await backend.waitForTermination()  // and the request is cancelled
    }

    /// The placeholder carried the citations, so the orphaned bubble offered a
    /// bibliography for an answer that never said anything; and it wasn't
    /// stored, so the reopened thread differed from the screen.
    @Test func anAnswerThatFailsBeforeItsFirstTokenLeavesNoEmptyBubble() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.finish(throwing: InferenceError(
            "Claude did not respond within a minute. Check your connection and try again."))
        let outcome = await generation.outcome
        #expect(outcome.answerText == nil, "remove the bubble")
        #expect(!outcome.persistsAnswer)
        #expect(outcome.notice
            == "Error: Claude did not respond within a minute. Check your connection and try again.")
    }

    /// Starting a new thread stops the answer; what had arrived belongs to the
    /// thread it was asked in, and the new thread starts empty.
    @Test func startingANewThreadMidAnswerKeepsThePartialAnswerInTheOldOne() async throws {
        let history = ChatHistoryStore(database: try UserDatabase.inMemory())
        let asked = try await history.createConversation()
        try await history.addMessage(conversationId: asked.id, isUser: true, text: "What is baptism?")
        let citations = [Citation(contentId: 90, source: "The Confessions")]

        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.yield("Baptism is the sign")
        await waitFor("Baptism is the sign", in: generation)

        // The compose button: stop, and open a new thread.
        generation.stop()
        let fresh = try await history.createConversation()
        let outcome = await generation.outcome
        if outcome.persistsAnswer, let text = outcome.answerText {
            try await history.addMessage(conversationId: asked.id, isUser: false, text: text,
                                         citations: citations, generated: true)
        }

        #expect(try await history.messages(conversationId: fresh.id).isEmpty, "the new thread is empty")
        let stored = try await history.messages(conversationId: asked.id).map(\.text)
        #expect(stored == ["What is baptism?", "Baptism is the sign\n\n_(stopped)_"])
        #expect(!stored.contains { $0.contains("Error") })
    }

    // MARK: Outcomes

    @Test func updatesCarryTheAnswerSoFar() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        let consumer = Task {
            var seen: [String] = []
            for await text in generation.updates { seen.append(text) }
            return seen
        }
        for piece in ["Grace", " is", " a gift."] {
            backend.continuation.yield(piece)
            try? await Task.sleep(for: .milliseconds(20))
        }
        backend.continuation.finish()
        let seen = await consumer.value
        #expect(seen.last == "Grace is a gift.")
        #expect(seen.allSatisfy { "Grace is a gift.".hasPrefix($0) }, "cumulative, growing")
        let outcome = await generation.outcome
        #expect(outcome == .completed("Grace is a gift."))
        #expect(outcome.answerText == "Grace is a gift.")
        #expect(outcome.persistsAnswer)
    }

    /// A provider that returned nothing, or a model that only reasoned: an
    /// empty bubble reads as an answer still on its way.
    @Test func anEmptyAnswerIsSaidSo() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.finish()
        let outcome = await generation.outcome
        #expect(outcome == .completed(""))
        #expect(outcome.answerText
            == "The model returned an empty answer. Ask again, or choose a different backend in Settings.")
        #expect(outcome.persistsAnswer)
    }

    /// Stopped before a single token: nothing to keep, nothing to tell.
    @Test func stoppingBeforeAnyTokenLeavesNothing() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        generation.stop()
        let outcome = await generation.outcome
        #expect(outcome == .stopped(""))
        #expect(outcome.answerText == nil)
        #expect(!outcome.persistsAnswer)
        #expect(outcome.notice == nil)
    }

    /// What arrived stays on screen and is stored, with the error after it,
    /// so a reopened thread shows what the screen showed.
    @Test func aFailurePartwayKeepsAndStoresWhatArrivedAndAddsTheError() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.yield("Half an")
        await waitFor("Half an", in: generation)
        backend.continuation.finish(throwing: InferenceError("Ollama: out of memory"))
        let outcome = await generation.outcome
        #expect(outcome == .failed(message: "Error: Ollama: out of memory", partial: "Half an"))
        #expect(outcome.answerText == "Half an")
        #expect(outcome.persistsAnswer)
        #expect(outcome.notice == "Error: Ollama: out of memory")
    }

    /// The retry inside the Ollama backend is exhausted by now; a dropped
    /// connection almost always means the model was still loading.
    @Test func aDroppedConnectionIsExplained() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.finish(throwing: URLError(.networkConnectionLost))
        #expect(await generation.outcome.notice
            == "The model didn't respond in time — it may still be loading. Give it a moment and ask again.")
    }

    @Test func aPieceArrivingAfterStopIsNotKept() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.yield("Kept")
        await waitFor("Kept", in: generation)
        generation.stop()
        backend.continuation.yield(" and not this")
        #expect(await generation.outcome == .stopped("Kept"))
    }

    @Test func stoppingAfterTheEndChangesNothing() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream)
        backend.continuation.yield("Done.")
        backend.continuation.finish()
        #expect(await generation.outcome == .completed("Done."))
        generation.stop()
        generation.stop()
        #expect(await generation.outcome == .completed("Done."))
    }

    /// Leaving the screen mid-answer must not leave a request streaming into
    /// nothing.
    @Test func droppingTheGenerationCancelsTheBackend() async {
        let backend = ScriptedStream()
        var generation: Generation? = Generation(backend.stream)
        backend.continuation.yield("Streaming")
        if let generation { await waitFor("Streaming", in: generation) }
        generation = nil
        await backend.waitForTermination()
    }

    // MARK: The stall limit

    @Test func aBackendThatNeverStartsFailsAfterTheFirstAllowance() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream, firstChunkTimeout: .milliseconds(100),
                                    stallTimeout: .seconds(60))
        let outcome = await generation.outcome
        #expect(outcome == .failed(
            message: "Error: No answer arrived. The model may have stopped responding; ask again, or choose a "
                + "different backend in Settings.",
            partial: ""))
        await backend.waitForTermination()
    }

    @Test func anAnswerThatStallsFailsKeepingWhatArrived() async {
        let backend = ScriptedStream()
        let generation = Generation(backend.stream, firstChunkTimeout: .seconds(60),
                                    stallTimeout: .milliseconds(100))
        backend.continuation.yield("So far")
        let outcome = await generation.outcome
        #expect(outcome == .failed(
            message: "Error: The answer stopped arriving partway through. Ask again, or choose a different "
                + "backend in Settings.",
            partial: "So far"))
        #expect(outcome.answerText == "So far")
    }

    /// The limit is on silence, not on length: fifteen pieces 0.8 s apart
    /// (12 s in all) against a 1 s limit, on a clock the test moves.
    @Test func aSlowButSteadyAnswerIsNotCutOff() async {
        let clock = ManualClock()
        let backend = ScriptedStream()
        let generation = Generation(backend.stream, firstChunkTimeout: .seconds(1), stallTimeout: .seconds(1),
                                    clock: clock)
        var updates = generation.updates.makeAsyncIterator()
        var answer = ""
        for word in "abcdefghijklmno".map(String.init) {
            await clock.waitForSleepers()
            clock.advance(by: .milliseconds(800))
            backend.continuation.yield(word)
            answer += word
            while let text = await updates.next(), text != answer {}
        }
        backend.continuation.finish()
        #expect(await generation.outcome == .completed(answer))
    }

    /// Exactly the allowance after the last piece, and no later, even when
    /// the first allowance is longer than the idle one.
    @Test func theStallLimitRunsFromTheLastPiece() async {
        let clock = ManualClock()
        let backend = ScriptedStream()
        let generation = Generation(backend.stream, firstChunkTimeout: .seconds(300), stallTimeout: .seconds(120),
                                    clock: clock)
        var updates = generation.updates.makeAsyncIterator()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(10))
        backend.continuation.yield("So far")
        _ = await updates.next()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(110))  // t = 120: the old wake-up, 110 s after the piece
        await clock.waitForSleepers()
        clock.advance(by: .seconds(9))  // 119 s of silence: still fine
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))  // 120 s
        let outcome = await generation.outcome
        #expect(outcome.notice == "Error: The answer stopped arriving partway through. Ask again, or choose a "
            + "different backend in Settings.")
        #expect(clock.now.offset == .seconds(130))
    }

    /// Stop wins over a stall that fires at the same time.
    @Test func stopWinsOverAStall() async {
        let clock = ManualClock()
        let backend = ScriptedStream()
        let generation = Generation(backend.stream, firstChunkTimeout: .seconds(1), stallTimeout: .seconds(1),
                                    clock: clock)
        await clock.waitForSleepers()
        generation.stop()
        clock.advance(by: .seconds(5))
        #expect(await generation.outcome == .stopped(""))
    }
}

@Suite struct ChatTextTests {
    @Test func wordingIsTheFlutterScreens() {
        #expect(ChatText.noResults
            == "I couldn't find anything in the library for that. Try different wording, or browse by tradition.")
        #expect(ChatText.searchOnly(passageCount: 6)
            == "Search-only mode is on, so no answer is generated. These 6 passages matched your question:")
        #expect(ChatText.backendUnavailable == "That backend is unavailable.")
        #expect(ChatText.stoppedSuffix == "\n\n_(stopped)_")
    }

    @Test(arguments: [URLError.Code.networkConnectionLost, .cannotConnectToHost, .timedOut, .notConnectedToInternet])
    func connectionFailuresAreExplained(_ code: URLError.Code) {
        #expect(ChatText.describe(URLError(code))
            == "The model didn't respond in time — it may still be loading. Give it a moment and ask again.")
    }

    @Test func otherFailuresAreErrorAndTheirMessage() {
        #expect(ChatText.describe(InferenceError("Grok rate limit reached. Try again shortly."))
            == "Error: Grok rate limit reached. Try again shortly.")
        #expect(ChatText.describe(URLError(.badURL)).hasPrefix("Error: "))
        #expect(ChatText.describe(POSIXError(.ECONNRESET))
            == "The model didn't respond in time — it may still be loading. Give it a moment and ask again.")
    }
}

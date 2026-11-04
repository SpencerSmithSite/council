// Covers Inference/ReasoningFilter.swift. Every case of
// test/reasoning_filter_test.dart, in its order, then what the Swift port adds
// (the synchronous API, errors and cancellation passing through).
//
// The failure the filter exists to stop was a rendering one: the markers
// reached the transcript intact, the Markdown renderer dropped them as unknown
// HTML, and the reasoning was left looking like prose. So the assertions are
// all about what survives, never about what the markers looked like on the
// way through.

import Testing
@testable import CouncilCore

@Suite struct ReasoningFilterTests {
    /// Feed `chunks` through the stream transformer and collect the answer.
    func filtered(_ chunks: [String]) async throws -> String {
        try await pieces(chunks).joined()
    }

    func pieces(_ chunks: [String]) async throws -> [String] {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
        var out: [String] = []
        for try await piece in ReasoningFilter.strip(stream) { out.append(piece) }
        return out
    }

    /// The same text one code unit at a time (every test string is in the
    /// BMP), so every marker is split across a boundary: the case a naive
    /// replace on each chunk gets wrong.
    func perCharacter(_ text: String) async throws -> String {
        try await filtered(text.map(String.init))
    }

    // MARK: A stream with no reasoning in it

    @Test func passesThroughUnchanged() async throws {
        #expect(try await filtered(["John ", "baptised ", "in the Jordan."]) == "John baptised in the Jordan.")
    }

    @Test func survivesBeingSplitCharacterByCharacter() async throws {
        #expect(try await perCharacter("Baptism [1] is discussed in [2].") == "Baptism [1] is discussed in [2].")
    }

    @Test func keepsALoneAngleBracketThatStartsNoMarker() async throws {
        #expect(try await perCharacter("2 < 3 and <b> is not <think") == "2 < 3 and <b> is not <think")
    }

    /// Pinned as a known limit rather than left to be discovered: a template
    /// that prefills `<think>` makes the closer the first thing the model
    /// emits, and by then the reasoning has already been streamed. The marker
    /// itself is still removed.
    @Test func reasoningOpenedBeforeTheStreamStartedIsNotCaught() async throws {
        #expect(try await perCharacter("reasoning with no opener</think>\n\nThe answer.")
            == "reasoning with no opener\n\nThe answer.")
    }

    // MARK: <think> blocks, the form Qwen 3 emits itself

    @Test func thinkBlocksAreRemoved() async throws {
        #expect(try await filtered(["<think>First, source [1]…</think>1. John:"]) == "1. John:")
    }

    @Test func thinkBlocksAreRemovedWhenEveryMarkerStraddlesAChunk() async throws {
        #expect(try await perCharacter("<think>scratch work</think>\n\nThe answer.") == "The answer.")
    }

    @Test func thinkBlocksDoNotSwallowTextThatPrecedesThem() async throws {
        #expect(try await perCharacter("Before.<think>hidden</think>After.") == "Before.After.")
    }

    @Test func thinkBlocksAreRemovedMoreThanOnce() async throws {
        #expect(try await perCharacter("<think>a</think>One.<think>b</think>Two.") == "One.Two.")
    }

    // MARK: <|channel>thought blocks, the form the SDK rewrites into

    @Test func channelBlocksAreRemoved() async throws {
        #expect(try await perCharacter("<|channel>thought\nreasoning here<channel|>The answer.") == "The answer.")
    }

    @Test func channelBlocksAreRemovedWhenMixedWithAThinkBlock() async throws {
        #expect(try await perCharacter("<think>a</think><|channel>thought\nb<channel|>Answer.") == "Answer.")
    }

    // MARK: Edges

    /// The whole budget went to thinking. There is no answer, and the point of
    /// the filter is that the scratch work doesn't become one.
    @Test func reasoningTheModelNeverClosedIsDroppedNotPrinted() async throws {
        #expect(try await perCharacter("<think>on and on and the tokens ran out") == "")
    }

    /// Leading only. Trimming trailing whitespace would mean holding every run
    /// of it back until the next token proved the answer had ended.
    @Test func theBlankLineAModelLeavesAfterThinkIsTrimmed() async throws {
        #expect(try await perCharacter("<think>x</think>\n\n\nAnswer.\n") == "Answer.\n")
    }

    @Test func whitespaceInsideTheAnswerIsTheModelsToKeep() async throws {
        #expect(try await perCharacter("<think>x</think>1. John\n\n2. Paul") == "1. John\n\n2. Paul")
    }

    @Test func anEmptyStreamYieldsNothing() async throws {
        #expect(try await filtered([]) == "")
    }

    /// The reader watches this arrive, so the filter mustn't buffer the whole
    /// answer waiting for a marker that never comes. Only a possible partial
    /// marker may be withheld, which is at most a few characters.
    @Test func nothingIsHeldBackOnceTheAnswerIsUnderWay() async throws {
        #expect(try await pieces(["The Didache ", "says ", "plainly"]).count == 3)
    }

    // MARK: The Swift port

    @Test func thePartialMarkerHeldBackIsReleasedWhenItTurnsOutNotToBeOne() {
        var filter = ReasoningFilter()
        #expect(filter.feed("Grace <th") == ["Grace "])
        #expect(filter.feed("ings") == ["<things"])
        #expect(filter.finish() == [])
    }

    @Test func aPartialMarkerAtTheEndIsEmittedWhenTheStreamEnds() {
        var filter = ReasoningFilter()
        #expect(filter.feed("Amen <thi") == ["Amen "])
        #expect(filter.finish() == ["<thi"])
    }

    /// Dart's whitespace set, not Swift's: U+0085 and U+FEFF are trimmed from
    /// the leading edge, U+200B (not whitespace in Dart) is kept.
    @Test func theLeadingTrimUsesDartsWhitespace() async throws {
        #expect(try await filtered(["<think>x</think>\u{85}\u{FEFF}\u{3000} Answer"]) == "Answer")
        #expect(try await filtered(["<think>x</think>\u{200B}Answer"]) == "\u{200B}Answer")
    }

    @Test func nonBMPTextNextToAMarkerSurvives() async throws {
        #expect(try await perCharacterScalars("<think>𝔊</think>𝔊race 🙏") == "𝔊race 🙏")
    }

    func perCharacterScalars(_ text: String) async throws -> String {
        try await filtered(text.unicodeScalars.map { String($0) })
    }

    @Test func anUpstreamErrorArrivesAfterWhatPrecededIt() async throws {
        struct Boom: Error {}
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuation.yield("<think>x</think>Partial")
        continuation.finish(throwing: Boom())
        var received: [String] = []
        await #expect(throws: Boom.self) {
            for try await piece in ReasoningFilter.strip(stream) { received.append(piece) }
        }
        #expect(received == ["Partial"])
    }

    /// Cancelling the consumer must reach the backend, or a stopped answer
    /// keeps generating.
    @Test func cancellingTheConsumerTerminatesTheUpstream() async throws {
        let terminated = AsyncStream<Void>.makeStream()
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuation.onTermination = { _ in terminated.continuation.yield() }
        let consumer = Task {
            for try await _ in ReasoningFilter.strip(stream) {}
        }
        continuation.yield("Silence follows")
        consumer.cancel()
        var iterator = terminated.stream.makeAsyncIterator()
        await iterator.next()
    }
}

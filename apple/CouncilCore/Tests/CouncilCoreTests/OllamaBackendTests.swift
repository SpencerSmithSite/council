// Covers Inference/OllamaBackend.swift and the line reassembly in
// Inference/HTTPTransport.swift. The `wholeLines` and Ollama streaming cases
// are test/stream_lines_test.dart's; the rest cover the status check, the
// request, the cold-start retry and failures, against recorded NDJSON.

import Foundation
import Testing
@testable import CouncilCore

/// `wholeLines`, chunk boundaries and all.
@Suite struct LineAssemblerTests {
    func lines(_ chunks: [String]) -> [String] {
        var assembler = LineAssembler()
        var out: [String] = []
        for chunk in chunks { out += assembler.feed(Array(chunk.utf8)) }
        if let tail = assembler.finish() { out.append(tail) }
        return out
    }

    @Test func aLineSplitAcrossTwoChunksArrivesInOnePiece() {
        #expect(lines(["he", "llo\n"]) == ["hello"])
    }

    @Test func severalLinesInASingleChunkAllComeThrough() {
        #expect(lines(["a\nb\nc\n"]) == ["a", "b", "c"])
    }

    @Test func aChunkBoundaryOnTheNewlineItselfIsNotALostLine() {
        #expect(lines(["a\n", "\nb\n"]) == ["a", "", "b"])
    }

    /// A server that ends its last line without terminating it shouldn't cost
    /// the reader that line.
    @Test func aTrailingFragmentWithNoClosingNewlineIsStillEmitted() {
        #expect(lines(["a\nb"]) == ["a", "b"])
    }

    @Test func anEmptyStreamYieldsNothingRatherThanOneEmptyLine() {
        #expect(lines([]).isEmpty)
    }

    @Test func aSingleByteAtATimeStillReassembles() {
        #expect(lines("first line\nsecond line\n".map(String.init)) == ["first line", "second line"])
    }

    /// Bytes, not characters: a multi-byte character split across chunks is
    /// decoded whole.
    @Test func aCharacterSplitAcrossChunksIsDecodedWhole() {
        var assembler = LineAssembler()
        var out: [String] = []
        for byte in Array("Ἐν ἀρχῇ 🙏\n".utf8) { out += assembler.feed([byte]) }
        #expect(out == ["Ἐν ἀρχῇ 🙏"])
    }

    @Test func aCarriageReturnStaysOnTheLineForTheParserToTrim() {
        #expect(lines(["data: x\r\n"]) == ["data: x\r"])
    }
}

/// One NDJSON object per line, as Ollama sends them.
func ollamaToken(_ text: String, done: Bool = false) -> String {
    OrderedJSON.object([("response", .string(text)), ("done", .bool(done))]).dartEncoded + "\n"
}

@Suite struct OllamaBackendTests {
    func backend(_ transport: FakeTransport, host: String = "http://192.168.1.20:11434", model: String = "qwen3:8b")
        -> OllamaBackend
    {
        OllamaBackend(host: host, model: model, transport: transport, retryBackoff: .zero)
    }

    // MARK: Ollama streaming doesn't drop a word at a chunk boundary

    /// The two halves of one object each fail to parse, both are skipped as
    /// malformed, and the word vanishes with no error anywhere.
    @Test func aTokenWhoseJSONIsSplitInHalfIsNotLost() async {
        let whole = ollamaToken("justification")
        let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        let transport = FakeTransport(.chunks([
            ollamaToken("On "), String(whole[..<cut]), String(whole[cut...]), ollamaToken(" alone", done: true),
        ]))
        let result = await drain(backend(transport).rawStream(prompt: "anything", system: nil))
        #expect(result.pieces.joined() == "On justification alone")
        #expect(result.error == nil)
    }

    @Test func aStreamArrivingOneByteAtATimeIsIntact() async {
        let payload = [ollamaToken("Grace"), ollamaToken(" and"), ollamaToken(" peace"), ollamaToken(".", done: true)]
            .joined()
        let result = await drain(backend(FakeTransport(.bytewise(payload))).rawStream(prompt: "anything", system: nil))
        #expect(result.pieces.joined() == "Grace and peace.")
    }

    /// The old catch swallowed half-lines along with real garbage. It still
    /// has to swallow the real garbage.
    @Test func aGenuinelyMalformedLineIsStillSkipped() async {
        let transport = FakeTransport(.chunks([
            "this is not json at all\n", "[1, 2]\n", "\"a string\"\n", "\n", ollamaToken("Amen"),
            ollamaToken(".", done: true),
        ]))
        #expect(await drain(backend(transport).rawStream(prompt: "anything", system: nil)).pieces.joined() == "Amen.")
    }

    @Test func doneStopsTheStreamEvenWithMoreLinesBehindIt() async {
        let transport = FakeTransport(.chunks([
            ollamaToken("Enough"), ollamaToken(".", done: true), ollamaToken(" and then some"),
        ]))
        #expect(await drain(backend(transport).rawStream(prompt: "anything", system: nil)).pieces.joined()
            == "Enough.")
    }

    // MARK: The rest

    @Test func aStreamThatEndsWithoutDoneStillEndsCleanly() async {
        let transport = FakeTransport(.body(ollamaToken("Partial") + #"{"response":" tail","done":false}"#))
        let result = await drain(backend(transport).rawStream(prompt: "q", system: nil))
        #expect(result.pieces == ["Partial", " tail"])
        #expect(result.error == nil)
    }

    /// The request, byte for byte what `OllamaService.generateStream` sends.
    @Test func theRequestIsWhatTheFlutterAppSends() async throws {
        let transport = FakeTransport(.body(ollamaToken("", done: true)))
        _ = await drain(backend(transport).generate(prompt: "P \"q\"", system: "S"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://192.168.1.20:11434/api/generate")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(request.bodyText == #"{"model":"qwen3:8b","prompt":"P \"q\"","system":"S","stream":true,"#
            + #""keep_alive":"30m","options":{"temperature":0.7}}"#)
    }

    @Test func noSystemPromptIsSentAsNull() async throws {
        let transport = FakeTransport(.body(ollamaToken("", done: true)))
        _ = await drain(backend(transport, model: "").generate(prompt: "P", system: nil))
        #expect(try #require(transport.requests.first).bodyText
            == #"{"model":"llama3.2","prompt":"P","system":null,"stream":true,"keep_alive":"30m","#
            + #""options":{"temperature":0.7}}"#)
    }

    /// `qwen3` and `deepseek-r1` think out loud in `<think>` markers.
    @Test func reasoningIsFilteredOut() async {
        let transport = FakeTransport(.chunks([
            ollamaToken("<thi"), ollamaToken("nk>Looking at [1]…</th"), ollamaToken("ink>\n\nThe"),
            ollamaToken(" answer.", done: true),
        ]))
        #expect(await drain(backend(transport).generate(prompt: "q", system: nil)).pieces.joined() == "The answer.")
    }

    /// A cold model load resets the socket before the first token; once the
    /// model is resident the next attempt streams.
    @Test func aConnectionDroppedBeforeTheFirstTokenIsRetried() async {
        let transport = FakeTransport(
            .failing(URLError(.networkConnectionLost)),
            Reply(chunks: [], bodyError: URLError(.networkConnectionLost)),
            .body(ollamaToken("Warm now.", done: true)))
        let result = await drain(backend(transport).generate(prompt: "q", system: nil))
        #expect(result.pieces.joined() == "Warm now.")
        #expect(transport.requests.count == 3)
    }

    @Test func retriesStopAfterThreeAttempts() async throws {
        let transport = FakeTransport(.failing(URLError(.cannotConnectToHost)))
        let result = await drain(backend(transport).generate(prompt: "q", system: nil))
        #expect((result.error as? URLError)?.code == .cannotConnectToHost,
                "passed through so the chat screen can recognise a dropped connection")
        #expect(transport.requests.count == 3)
        #expect(ChatText.describe(try #require(result.error))
            == "The model didn't respond in time — it may still be loading. Give it a moment and ask again.")
    }

    /// A mid-answer drop must never be replayed as a duplicated answer.
    @Test func aDropAfterTheFirstTokenIsNotRetried() async {
        var reply = FakeTransport.Reply.chunks([ollamaToken("Half an")])
        reply.bodyError = URLError(.networkConnectionLost)
        let transport = FakeTransport(reply, .body(ollamaToken("Duplicate", done: true)))
        let result = await drain(backend(transport).generate(prompt: "q", system: nil))
        #expect(result.pieces.joined() == "Half an")
        #expect((result.error as? URLError)?.code == .networkConnectionLost)
        #expect(transport.requests.count == 1)
    }

    @Test func aNon200ReplyIsAnErrorAndIsNotRetried() async {
        let transport = FakeTransport(.body(#"{"error":"model 'x' not found"}"#, status: 404))
        let result = await drain(backend(transport).generate(prompt: "q", system: nil))
        #expect(result.error as? InferenceError == InferenceError("Failed to generate: 404"))
        #expect(transport.requests.count == 1)
    }

    /// Dart skips these; the answer then just stops and is stored as if it
    /// were whole.
    @Test func anErrorLineMidStreamEndsTheAnswerWithIt() async {
        let transport = FakeTransport(.chunks([ollamaToken("Partial"), #"{"error":"out of memory"}"# + "\n"]))
        let result = await drain(backend(transport).generate(prompt: "q", system: nil))
        #expect(result.pieces.joined() == "Partial")
        #expect(result.error as? InferenceError == InferenceError("Ollama: out of memory"))
    }

    @Test func cancellingTheConsumerClosesTheConnection() async throws {
        var reply = FakeTransport.Reply.chunks([ollamaToken("Streaming")])
        reply.hangAfterChunks = true
        let transport = FakeTransport(reply)
        let stream = backend(transport).generate(prompt: "q", system: nil)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await _ in stream { signal.yield() }
        }
        for await _ in started { break }
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<100 where transport.bodyTerminations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.bodyTerminations == 1)
    }

    // MARK: Status and models

    static let tags = #"{"models":[{"name":"qwen3:8b","size":1},{"name":"llama3.2:latest"}]}"#

    @Test func modelsAreListedFromTags() async throws {
        let transport = FakeTransport(.body(Self.tags))
        #expect(await backend(transport).availableModels() == ["qwen3:8b", "llama3.2:latest"])
        #expect(try #require(transport.requests.first).url?.absoluteString == "http://192.168.1.20:11434/api/tags")
    }

    @Test(arguments: [
        FakeTransport.Reply.body("{}"), .body("not json"), .body(Self.tags, status: 500),
        .body(#"{"models":[{"name":"a"},{"size":2}]}"#), .failing(URLError(.cannotConnectToHost)),
    ])
    func anythingUnexpectedListsNoModels(_ reply: FakeTransport.Reply) async {
        #expect(await backend(FakeTransport(reply)).availableModels().isEmpty)
    }

    @Test func availableWhenTheChosenModelIsPulled() async {
        let status = await backend(FakeTransport(.body(Self.tags)), model: "llama3.2").checkStatus()
        #expect(status == .available("Connected to http://192.168.1.20:11434"), "a prefix match, as in Dart")
    }

    @Test func statusSaysWhatToFix() async {
        #expect(await backend(FakeTransport(.body(Self.tags)), host: "  ").checkStatus()
            == .unavailable("No Ollama host configured."))
        #expect(await backend(FakeTransport(.failing(URLError(.cannotConnectToHost)))).checkStatus()
            == .unavailable("Could not reach Ollama at http://192.168.1.20:11434. Check that it is running and, if it "
                + "is on another machine, that the address is correct."))
        #expect(await backend(FakeTransport(.body(#"{"models":[]}"#))).checkStatus()
            == .unavailable("Ollama is running but has no models. Pull one, e.g. \"ollama pull llama3.2\"."))
        #expect(await backend(FakeTransport(.body(Self.tags)), model: " ").checkStatus()
            == .unavailable("Connected to http://192.168.1.20:11434, but no model is selected. Choose one from "
                + "the list in AI Backend settings."))
        #expect(await backend(FakeTransport(.body(Self.tags)), model: "mistral").checkStatus()
            == .unavailable("Ollama is running but \"mistral\" is not installed. Pull it or pick another model."))
    }

    /// A host that accepts the connection and then says nothing mustn't leave
    /// the Test button spinning.
    @Test(.timeLimit(.minutes(1)))
    func aHostThatNeverAnswersIsUnreachableWithinFiveSeconds() async {
        var reply = FakeTransport.Reply()
        reply.hangBeforeHeaders = true
        let started = ContinuousClock.now
        #expect(await backend(FakeTransport(reply)).isReachable() == false)
        #expect(ContinuousClock.now - started < .seconds(7))
    }

    @Test func warmingUpSendsTheEmptyPrompt() async throws {
        let transport = FakeTransport(.body("{}"))
        await backend(transport).warmUp()
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/api/generate")
        #expect(request.bodyText == #"{"model":"qwen3:8b","prompt":"","stream":false,"keep_alive":"30m"}"#)
    }

    @Test func describesItself() {
        let ollama = backend(FakeTransport(.body("")))
        #expect(ollama.id == .ollama)
        #expect(ollama.isPrivate)
        #expect(ollama.contextBudgetChars == 12000)
        #expect(OllamaBackend.defaultHost == "http://localhost:11434")
        #expect(OllamaBackend.defaultModel == "")
    }
}

typealias Reply = FakeTransport.Reply

// Covers Inference/CloudBackend.swift against recorded Server-Sent Events
// streams in each provider's real shape, split at awkward places, and the
// error bodies each provider sends. Nothing here touches a network.

import Foundation
import Testing
@testable import CouncilCore

enum RecordedSSE {
    /// A Messages API stream, with the events Anthropic sends around the text:
    /// message_start, ping, a thinking delta, block stop, message_delta.
    static let anthropic = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_01XFDUDYJgAACzvnptvVoYEL","type":"message","role":"assistant","content":[],"model":"claude-opus-4-8","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2950,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type": "ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Not for the reader."}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Grace is"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" unmerited favour [1] — \\"a gift\\" 🙏."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

        event: message_stop
        data: {"type":"message_stop"}


        """

    /// Chat Completions, as OpenAI and xAI stream it: a role-only first
    /// chunk, content deltas, an empty delta with the finish reason, [DONE].
    static let openAI = """
        data: {"id":"chatcmpl-AJ1","object":"chat.completion.chunk","created":1730000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_1","choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"logprobs":null,"finish_reason":null}]}

        data: {"id":"chatcmpl-AJ1","object":"chat.completion.chunk","created":1730000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_1","choices":[{"index":0,"delta":{"content":"Grace"},"logprobs":null,"finish_reason":null}]}

        : keep-alive

        data: {"id":"chatcmpl-AJ1","object":"chat.completion.chunk","created":1730000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_1","choices":[{"index":0,"delta":{"content":" alone [2]."},"logprobs":null,"finish_reason":null}]}

        data: {"id":"chatcmpl-AJ1","object":"chat.completion.chunk","created":1730000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_1","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}

        data: [DONE]


        """

    /// streamGenerateContent with alt=sse, which ends its lines in CRLF.
    static let gemini = [
        #"data: {"candidates": [{"content": {"parts": [{"text": "Faith"}],"role": "model"},"index": 0}],"usageMetadata": {"promptTokenCount": 2950,"totalTokenCount": 2951},"modelVersion": "gemini-2.0-flash"}"#,
        "",
        #"data: {"candidates": [{"content": {"parts": [{"text": " and works [3]."}],"role": "model"},"finishReason": "STOP","index": 0}],"usageMetadata": {"promptTokenCount": 2950,"candidatesTokenCount": 6,"totalTokenCount": 2956},"modelVersion": "gemini-2.0-flash"}"#,
        "",
        "",
    ].joined(separator: "\r\n")
}

@Suite struct CloudBackendTests {
    func backend(_ provider: CloudProvider, _ transport: FakeTransport, key: String = "sk-test",
                 model: String? = nil, firstByte: Duration = .seconds(60), idle: Duration = .seconds(60))
        -> CloudBackend
    {
        CloudBackend(provider: provider, model: model ?? provider.defaultModel, apiKey: key, transport: transport,
                     firstByteTimeout: firstByte, idleTimeout: idle)
    }

    /// Split into chunks of `size` bytes: every boundary lands somewhere new,
    /// mid-line, mid-JSON and mid-character.
    static func split(_ text: String, every size: Int) -> FakeTransport.Reply {
        let bytes = Array(text.utf8)
        return FakeTransport.Reply(chunks: stride(from: 0, to: bytes.count, by: size).map {
            Data(bytes[$0..<min($0 + size, bytes.count)])
        })
    }

    // MARK: Streams

    @Test(arguments: [1, 3, 7, 64, 100_000])
    func anthropicStream(chunkSize: Int) async {
        let result = await drain(backend(.anthropic, FakeTransport(Self.split(RecordedSSE.anthropic, every: chunkSize)))
            .generate(prompt: "q", system: "s"))
        #expect(result.error == nil)
        #expect(result.pieces == ["Grace is", " unmerited favour [1] — \"a gift\" 🙏."])
    }

    @Test(arguments: [CloudProvider.openai, .xai], [1, 5, 64])
    func openAIShapedStream(provider: CloudProvider, chunkSize: Int) async {
        let result = await drain(backend(provider, FakeTransport(Self.split(RecordedSSE.openAI, every: chunkSize)))
            .generate(prompt: "q", system: nil))
        #expect(result.error == nil)
        #expect(result.pieces == ["Grace", " alone [2]."])
    }

    @Test(arguments: [1, 9, 100_000])
    func geminiStream(chunkSize: Int) async {
        let result = await drain(backend(.gemini, FakeTransport(Self.split(RecordedSSE.gemini, every: chunkSize)))
            .generate(prompt: "q", system: "s"))
        #expect(result.error == nil)
        #expect(result.pieces == ["Faith", " and works [3]."])
    }

    /// A final line with no newline after it still counts.
    @Test func anUnterminatedLastEventIsRead() async {
        let transport = FakeTransport(.body(#"data: {"choices":[{"delta":{"content":"Last"}}]}"#))
        #expect(await drain(backend(.openai, transport).generate(prompt: "q", system: nil)).pieces == ["Last"])
    }

    /// Payloads of a shape the parser doesn't expect are skipped, where the
    /// Dart code throws a type error and ends the answer with it.
    @Test func unexpectedShapesAreSkipped() async {
        let transport = FakeTransport(.body("""
            data: {"choices":"none"}
            data: {"choices":[]}
            data: {"choices":[1]}
            data: {"choices":[{"delta":{"content":5}}]}
            data: [1,2]
            data:
            data:   {"choices":[{"delta":{"content":"ok"}}]}
            """))
        #expect(await drain(backend(.openai, transport).generate(prompt: "q", system: nil)).pieces == ["ok"])
    }

    // MARK: Requests

    @Test func anthropicRequest() async throws {
        let transport = FakeTransport(.body(""))
        _ = await drain(backend(.anthropic, transport, key: "sk-ant-1").generate(prompt: "P", system: "S"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-1")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.bodyText == #"{"model":"claude-opus-4-8","max_tokens":4096,"system":"S","#
            + #""messages":[{"role":"user","content":"P"}],"stream":true}"#)
    }

    @Test func anthropicRequestWithoutASystemPrompt() async throws {
        let transport = FakeTransport(.body(""))
        _ = await drain(backend(.anthropic, transport).generate(prompt: "P", system: nil))
        #expect(try #require(transport.requests.first).bodyText
            == #"{"model":"claude-opus-4-8","max_tokens":4096,"messages":[{"role":"user","content":"P"}],"stream":true}"#)
    }

    @Test(arguments: [(CloudProvider.openai, "https://api.openai.com/v1/chat/completions", "gpt-4o"),
                      (.xai, "https://api.x.ai/v1/chat/completions", "grok-2-latest")])
    func openAIShapedRequest(provider: CloudProvider, url: String, model: String) async throws {
        let transport = FakeTransport(.body(""))
        _ = await drain(backend(provider, transport, key: "k").generate(prompt: "P", system: "S"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.bodyText == #"{"model":"\#(model)","messages":[{"role":"system","content":"S"},"#
            + #"{"role":"user","content":"P"}],"stream":true}"#)
    }

    @Test func geminiRequest() async throws {
        let transport = FakeTransport(.body(""))
        _ = await drain(backend(.gemini, transport, key: "AIzaKey-_1").generate(prompt: "P", system: "S"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/"
            + "gemini-2.0-flash:streamGenerateContent?alt=sse&key=AIzaKey-_1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.bodyText == #"{"systemInstruction":{"parts":[{"text":"S"}]},"#
            + #""contents":[{"role":"user","parts":[{"text":"P"}]}]}"#)
    }

    @Test func geminiRequestWithoutASystemPrompt() async throws {
        let transport = FakeTransport(.body(""))
        _ = await drain(backend(.gemini, transport).generate(prompt: "P", system: nil))
        #expect(try #require(transport.requests.first).bodyText
            == #"{"contents":[{"role":"user","parts":[{"text":"P"}]}]}"#)
    }

    // MARK: Errors

    @Test(arguments: [
        (CloudProvider.anthropic, 401,
         #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011"}"#,
         "Claude: invalid x-api-key"),
        (.openai, 401,
         #"{"error":{"message":"Incorrect API key provided: sk-abc. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#,
         "ChatGPT: Incorrect API key provided: sk-abc. You can find your API key at https://platform.openai.com/account/api-keys."),
        (.gemini, 400,
         #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#,
         "Gemini: API key not valid. Please pass a valid API key."),
        (.anthropic, 529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
         "Claude: Overloaded"),
        (.xai, 400, #"{"message":"Model not found"}"#, "Grok: Model not found"),
        (.anthropic, 401, "<html>Unauthorized</html>", "Claude rejected the API key. Check it in Settings."),
        (.openai, 403, "", "ChatGPT rejected the API key. Check it in Settings."),
        (.gemini, 404, #"{"error":{"message":""}}"#, "Gemini does not recognise the model \"gemini-2.0-flash\"."),
        (.xai, 429, "Too Many Requests", "Grok rate limit reached. Try again shortly."),
        (.anthropic, 500, "{}", "Claude request failed (HTTP 500)."),
        // Some OpenAI-shaped APIs put the message in `error` itself. Dart throws a type error
        // reading it.
        (.xai, 401, #"{"code":"Client specified an invalid argument","error":"Incorrect API key"}"#,
         "Grok: Incorrect API key"),
    ])
    func errorBodiesBecomeReadable(provider: CloudProvider, status: Int, body: String, expected: String) async {
        let transport = FakeTransport(.body(body, status: status))
        let result = await drain(backend(provider, transport).generate(prompt: "q", system: nil))
        #expect(result.pieces.isEmpty)
        #expect(result.error as? InferenceError == InferenceError(expected))
    }

    /// Dart ignores these, so an answer cut off by an overloaded server is
    /// stored as if it were complete.
    @Test func anErrorEventMidStreamEndsTheAnswerWithIt() async {
        let transport = FakeTransport(.body("""
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}

            event: error
            data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}

            """))
        let result = await drain(backend(.anthropic, transport).generate(prompt: "q", system: nil))
        #expect(result.pieces == ["Half"])
        #expect(result.error as? InferenceError == InferenceError("Claude: Overloaded"))
    }

    @Test func anOpenAIErrorPayloadMidStreamEndsTheAnswerWithIt() async {
        let transport = FakeTransport(.body("""
            data: {"choices":[{"delta":{"content":"Half"}}]}

            data: {"error":{"message":"The server had an error while processing your request.","type":"server_error"}}

            """))
        let result = await drain(backend(.openai, transport).generate(prompt: "q", system: nil))
        #expect(result.pieces == ["Half"])
        #expect(result.error as? InferenceError
            == InferenceError("ChatGPT: The server had an error while processing your request."))
    }

    @Test func aTransportFailureIsPassedThrough() async {
        let transport = FakeTransport(.failing(URLError(.notConnectedToInternet)))
        let result = await drain(backend(.openai, transport).generate(prompt: "q", system: nil))
        #expect((result.error as? URLError)?.code == .notConnectedToInternet)
    }

    // MARK: Time limits

    /// A network that completes the handshake and swallows the request (a
    /// captive portal) used to leave the chat screen spinning forever.
    @Test(.timeLimit(.minutes(1)))
    func aProviderThatNeverAnswersTimesOut() async {
        var reply = FakeTransport.Reply()
        reply.hangBeforeHeaders = true
        let result = await drain(backend(.anthropic, FakeTransport(reply), firstByte: .milliseconds(100))
            .generate(prompt: "q", system: nil))
        #expect(result.error as? InferenceError
            == InferenceError("Claude did not respond within a minute. Check your connection and try again."))
    }

    @Test(.timeLimit(.minutes(1)))
    func anAnswerThatStopsArrivingTimesOutKeepingWhatArrived() async {
        var reply = FakeTransport.Reply.body(#"data: {"choices":[{"delta":{"content":"Partial"}}]}"# + "\n")
        reply.hangAfterChunks = true
        let transport = FakeTransport(reply)
        let result = await drain(backend(.openai, transport, idle: .milliseconds(150))
            .generate(prompt: "q", system: nil))
        #expect(result.pieces == ["Partial"])
        #expect(result.error as? InferenceError == InferenceError(
            "The answer from ChatGPT stopped arriving partway through. Check your connection and ask again."))
        #expect(transport.bodyTerminations == 1, "the stalled connection is closed")
    }

    // (That the limit is on silence rather than length is GenerationTests'
    // `aSlowButSteadyAnswerIsNotCutOff`, on a manual clock; the same Watchdog.)
    // MARK: Status and description

    @Test func statusNeedsAKey() async {
        #expect(await backend(.gemini, FakeTransport(.body("")), key: "").checkStatus()
            == .unavailable("No Gemini API key saved. Add one in Settings."))
        #expect(await backend(.gemini, FakeTransport(.body("")), key: " \n").checkStatus()
            == .unavailable("No Gemini API key saved. Add one in Settings."))
        #expect(await backend(.gemini, FakeTransport(.body("")), key: "AIza").checkStatus()
            == .available("Using your Gemini key"))
    }

    @Test func describesWhereQuestionsGo() async {
        let claude = backend(.anthropic, FakeTransport(.body("")))
        #expect(claude.id == .cloud)
        #expect(claude.displayName == "Claude")
        #expect(!claude.isPrivate)
        #expect(claude.contextBudgetChars == 60000)
        #expect(claude.summary == "Uses your own Claude API key. Questions and the retrieved passages are sent to "
            + "api.anthropic.com, where Claude's own privacy policy and data-retention terms apply — not this "
            + "app's. Council cannot control how long they keep your questions or what they do with them.")
        #expect(await claude.availableModels() == ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"])
    }

    @Test func providersAreFlutters() {
        #expect(CloudProvider.allCases.map(\.id) == ["anthropic", "openai", "gemini", "xai"])
        #expect(CloudProvider.allCases.map(\.label) == ["Claude", "ChatGPT", "Gemini", "Grok"])
        #expect(CloudProvider.allCases.map(\.defaultModel)
            == ["claude-opus-4-8", "gpt-4o", "gemini-2.0-flash", "grok-2-latest"])
        #expect(CloudProvider.allCases.map(\.host)
            == ["api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com", "api.x.ai"])
        #expect(CloudProvider.allCases.allSatisfy { $0.models.first == $0.defaultModel })
        #expect(CloudProvider(id: "mistral") == .anthropic)
        #expect(CloudProvider(id: "xai") == .xai)
    }
}

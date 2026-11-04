// Port of lib/src/services/inference/cloud_backend.dart.

import Foundation

/// A cloud provider the reader holds their own API key for.
///
/// The raw value is the id the Flutter app stores under `cloud_provider` and
/// uses in its keychain key names, so it must not change.
public enum CloudProvider: String, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case gemini
    case xai

    public var id: String { rawValue }

    /// `CloudProvider.fromId`: an unknown id is Anthropic.
    public init(id: String) {
        self = CloudProvider(rawValue: id) ?? .anthropic
    }

    /// The name readers know the product by, shown in the picker and in every
    /// message about this provider.
    public var label: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .xai: "Grok"
        }
    }

    /// For Gemini, the base the model name and method are appended to.
    public var endpoint: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .openai: "https://api.openai.com/v1/chat/completions"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/models"
        case .xai: "https://api.x.ai/v1/chat/completions"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-4-8"
        case .openai: "gpt-4o"
        case .gemini: "gemini-2.0-flash"
        case .xai: "grok-2-latest"
        }
    }

    /// The models offered in the picker, the default first.
    public var models: [String] {
        switch self {
        case .anthropic: ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]
        case .openai: ["gpt-4o", "gpt-4o-mini"]
        case .gemini: ["gemini-2.0-flash", "gemini-1.5-pro"]
        case .xai: ["grok-2-latest"]
        }
    }

    /// Where the reader goes to create a key, shown in Settings.
    public var keyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")!
        case .xai: URL(string: "https://console.x.ai")!
        }
    }

    /// The host questions are sent to, named in the privacy disclosure.
    public var host: String {
        URL(string: endpoint)?.host() ?? endpoint
    }
}

/// A cloud model, on the reader's own API key.
///
/// The one kind of backend that sends the question and the retrieved passages
/// off the device, so `isPrivate` is false and `summary` says where they go.
/// There is no SDK involved: each provider's REST API is spoken directly, with
/// its own request shape and its own Server-Sent Events payloads.
public struct CloudBackend: InferenceBackend {
    public let provider: CloudProvider
    public let model: String
    public let apiKey: String
    let transport: any HTTPTransport
    let firstByteTimeout: Duration
    let idleTimeout: Duration

    public init(provider: CloudProvider, model: String, apiKey: String,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.init(provider: provider, model: model, apiKey: apiKey, transport: transport,
                  firstByteTimeout: .seconds(60), idleTimeout: .seconds(60))
    }

    /// With the timeouts shortened, for tests.
    init(provider: CloudProvider, model: String, apiKey: String, transport: any HTTPTransport,
         firstByteTimeout: Duration, idleTimeout: Duration) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.firstByteTimeout = firstByteTimeout
        self.idleTimeout = idleTimeout
    }

    /// `cloud`, as Flutter stores the choice; the provider is stored
    /// separately (`InferenceSettings.cloudProvider`).
    public var id: InferenceBackendID { .cloud }
    public var displayName: String { provider.label }
    public var summary: String {
        "Uses your own \(provider.label) API key. Questions and the retrieved passages are sent to "
            + "\(provider.host), where \(provider.label)'s own privacy policy and data-retention terms apply — "
            + "not this app's. Council cannot control how long they keep your questions or what they do with them."
    }

    /// Explicitly not private: this is the one backend that leaves the device.
    public var isPrivate: Bool { false }

    /// Cloud models have very large context windows, so retrieval can be far
    /// more generous here than with an on-device model.
    public var contextBudgetChars: Int { 60000 }

    /// Available when a key is saved; no request is made, so a wrong key shows
    /// up on the first question as the provider's own rejection.
    public func checkStatus() async -> BackendStatus {
        if DartText.trimmed(apiKey).isEmpty {
            return .unavailable("No \(provider.label) API key saved. Add one in Settings.")
        }
        return .available("Using your \(provider.label) key")
    }

    public func availableModels() async -> [String] { provider.models }

    /// Streams the answer.
    ///
    /// Two time limits, each a minute. Neither had a bound once, and the
    /// failure was worse than a slow request: a network that completes the
    /// handshake and then swallows the request (a captive portal, a proxy
    /// holding the connection) left the request waiting forever, and the chat
    /// screen, which clears its loading state only when the stream ends, sat
    /// spinning with the composer disabled until the app was killed.
    ///
    /// - Until the provider starts answering (the response headers).
    /// - Between pieces of the answer. This bounds inactivity, not length: an
    ///   answer may take as long as it likes so long as it is still arriving.
    ///   All four providers send keep-alive events during a pause, so a minute
    ///   of silence is a stalled connection, not a model thinking.
    ///
    /// A non-200 reply becomes an `InferenceError` with the provider's own
    /// message when it sends one (almost always more useful than a status
    /// code), otherwise a sentence for the status. The error body gets a
    /// minute of its own; if it doesn't come, the status alone is described.
    public func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        let request = makeRequest(prompt: prompt, system: system)
        let transport = transport
        let provider = provider
        let model = model
        let firstByte = firstByteTimeout
        let idle = idleTimeout
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let response = try await withTimeLimit(firstByte, { try await transport.send(request) })
                    else {
                        throw InferenceError("\(provider.label) did not respond within a minute. Check your "
                            + "connection and try again.")
                    }
                    guard response.statusCode == 200 else {
                        let body = try await withTimeLimit(firstByte) { try await response.collect() } ?? Data()
                        throw InferenceError(Self.describeError(
                            provider: provider, model: model, status: response.statusCode,
                            body: String(decoding: body, as: UTF8.self)))
                    }
                    // The headers are in, so the idle allowance applies from
                    // the start of the body.
                    let watchdog = Watchdog(first: idle, idle: idle)
                    try await watchdog.run(timeout: { _ in
                        InferenceError("The answer from \(provider.label) stopped arriving partway through. "
                            + "Check your connection and ask again.")
                    }) {
                        var lines = LineAssembler()
                        for try await chunk in response.body {
                            watchdog.touch()
                            for line in lines.feed(chunk) {
                                if let text = try Self.sseText(line, provider: provider) { continuation.yield(text) }
                            }
                        }
                        if let tail = lines.finish(), let text = try Self.sseText(tail, provider: provider) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Requests

    func makeRequest(prompt: String, system: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // What package:http sends for a JSON string body.
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai, .xai:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .gemini:
            break  // The key travels in the query string.
        }
        request.httpBody = Data(body(prompt: prompt, system: system).dartEncoded.utf8)
        // Longer than both of ours, so that URLSession's own idle timeout
        // (60 s by default) never fires first with a vaguer error.
        request.timeoutInterval = 300
        return request
    }

    var url: URL {
        guard provider == .gemini else { return URL(string: provider.endpoint)! }
        // Gemini puts the model in the path and the key in the query string.
        // Percent-encoded, which changes nothing for a real key (letters,
        // digits, `-` and `_`) but keeps a mistyped one from making the URL
        // invalid.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        let key = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let path = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        return URL(string: "\(provider.endpoint)/\(path):streamGenerateContent?alt=sse&key=\(key)")
            ?? URL(string: provider.endpoint)!
    }

    /// The request body, key for key as Dart's `_body` writes it.
    func body(prompt: String, system: String?) -> OrderedJSON {
        switch provider {
        case .anthropic:
            var members: [(key: String, value: OrderedJSON)] = [
                ("model", .string(model)),
                // Required by the Messages API, unlike the OpenAI-shaped
                // providers.
                ("max_tokens", .int(4096)),
            ]
            if let system { members.append(("system", .string(system))) }
            members.append(("messages", .array([.object([("role", .string("user")), ("content", .string(prompt))])])))
            members.append(("stream", .bool(true)))
            // Deliberately no temperature, top_p or top_k: current Claude
            // models reject sampling parameters with a 400.
            return .object(members)

        case .openai, .xai:
            var messages: [OrderedJSON] = []
            if let system { messages.append(.object([("role", .string("system")), ("content", .string(system))])) }
            messages.append(.object([("role", .string("user")), ("content", .string(prompt))]))
            return .object([("model", .string(model)), ("messages", .array(messages)), ("stream", .bool(true))])

        case .gemini:
            var members: [(key: String, value: OrderedJSON)] = []
            if let system {
                members.append(("systemInstruction", .object([("parts", .array([.object([("text", .string(system))])]))])))
            }
            members.append(("contents", .array([.object([
                ("role", .string("user")),
                ("parts", .array([.object([("text", .string(prompt))])])),
            ])])))
            return .object(members)
        }
    }

    // MARK: - Responses

    /// The answer text in one line of a Server-Sent Events stream, if any.
    ///
    /// As in Dart: only `data:` lines count (the line and the payload are
    /// trimmed), `[DONE]` and empty payloads are skipped, and a payload that
    /// isn't JSON (a keep-alive, a comment) is ignored. Payloads of an
    /// unexpected shape are ignored too, where Dart would throw a type error
    /// and end the answer with it.
    ///
    /// One deliberate difference: an error event (Anthropic's
    /// `{"type":"error","error":{…}}`, or any payload with an `error`
    /// object, which is how the OpenAI-shaped APIs and Gemini report a failure
    /// after the reply has started) throws an `InferenceError` with the
    /// provider's message. Dart ignores these, so an answer cut off by an
    /// overloaded server is stored as if it were complete.
    static func sseText(_ line: String, provider: CloudProvider) throws -> String? {
        let trimmed = DartText.trimmed(line)
        guard DartText.hasPrefix(trimmed, "data:") else { return nil }
        let payload = DartText.trimmed(String(trimmed.dropFirst(5)))
        guard !payload.isEmpty, payload != "[DONE]", let data = OrderedJSON.parse(payload) else { return nil }
        if let message = errorMessage(in: data) {
            throw InferenceError("\(provider.label): \(message)")
        }
        let text: String?
        switch provider {
        case .anthropic:
            guard data["type"]?.stringValue == "content_block_delta",
                  let delta = data["delta"], delta["type"]?.stringValue == "text_delta"
            else { return nil }
            text = delta["text"]?.stringValue
        case .openai, .xai:
            text = data["choices"]?.arrayValue?.first?["delta"]?["content"]?.stringValue
        case .gemini:
            text = data["candidates"]?.arrayValue?.first?["content"]?["parts"]?.arrayValue?.first?["text"]?.stringValue
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The message of an error event, if `payload` is one.
    private static func errorMessage(in payload: OrderedJSON) -> String? {
        guard let error = payload["error"] else { return nil }
        if let text = error.stringValue, !text.isEmpty { return text }
        if payload["type"]?.stringValue == "error" || error.isObject {
            let message = error["message"]?.stringValue
            return (message?.isEmpty == false) ? message : "the request failed partway through."
        }
        return nil
    }

    /// Dart's `_describeError`: the provider's own message when the body
    /// carries one (`error.message`, or a top-level `message`), otherwise a
    /// sentence for the status.
    static func describeError(provider: CloudProvider, model: String, status: Int, body: String) -> String {
        if let decoded = OrderedJSON.parse(body), decoded.isObject {
            // `error` may be the message itself, as some OpenAI-shaped APIs send it. Dart
            // reads `decoded['error']?['message']`, which throws a type error
            // on a string, so that reply reached the reader as a type error.
            let message = decoded["error"]?["message"]?.stringValue ?? decoded["error"]?.stringValue
                ?? decoded["message"]?.stringValue
            if let message, !message.isEmpty { return "\(provider.label): \(message)" }
        }
        switch status {
        case 401, 403: return "\(provider.label) rejected the API key. Check it in Settings."
        case 404: return "\(provider.label) does not recognise the model \"\(model)\"."
        case 429: return "\(provider.label) rate limit reached. Try again shortly."
        default: return "\(provider.label) request failed (HTTP \(status))."
        }
    }
}

// Port of lib/src/services/inference/ollama_backend.dart and the parts of
// lib/src/services/ollama_service.dart it uses (`isAvailable`, `getModels`,
// `preload`, `generateStream`, `buildSystemPrompt`). The streaming cases of
// test/stream_lines_test.dart are in OllamaBackendTests.
//
// Not ported, because nothing in the app calls them: the non-streaming
// `generate`, `generateWithContext` with its `ContextPassage` (and that type's
// tests in test/ollama_service_test.dart; the chat screen budgets passages
// itself, see `ChatPrompt`), and `ensureModelAvailable`'s pull.

import Foundation

/// Ollama, on this machine or reachable over the local network or a VPN.
///
/// The host is the reader's to set rather than pinned to localhost: a phone
/// has no local Ollama, but there is often one on a desktop it can reach.
/// Reaching it needs the local-network usage description and the cleartext
/// exceptions in the app's Info.plist (apple/project.yml).
///
/// Call `warmUp()` whenever this becomes the active backend and its status is
/// available (on launch, on selecting Ollama, after editing the host or
/// model), as Flutter's `InferenceProvider.refreshStatus` does, so the
/// reader's first question streams from a loaded model.
public struct OllamaBackend: InferenceBackend {
    public static let defaultHost = "http://localhost:11434"

    /// Deliberately blank.
    ///
    /// Pre-filling a plausible name (it used to be `llama3.2`) means the app
    /// ships configured for a model the reader very likely hasn't pulled, and
    /// the first question then fails with "model not found" against a host
    /// that is working perfectly. Blank makes the real order of operations
    /// visible: enter the host, fetch what it has, choose from that.
    public static let defaultModel = ""

    /// The model `OllamaService` falls back on when none is chosen. Only ever
    /// sent if `generate` is called despite `checkStatus` saying no model is
    /// selected.
    static let fallbackModel = "llama3.2"

    public let host: String
    public let model: String
    let transport: any HTTPTransport
    /// The first retry's wait after a dropped connection; the second waits
    /// twice this. Two seconds, as in Dart; tests pass zero.
    let retryBackoff: Duration

    public init(host: String, model: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(host: host, model: model, transport: transport, retryBackoff: .seconds(2))
    }

    init(host: String, model: String, transport: any HTTPTransport, retryBackoff: Duration) {
        self.host = host
        self.model = model
        self.transport = transport
        self.retryBackoff = retryBackoff
    }

    public var id: InferenceBackendID { .ollama }
    public var displayName: String { "Ollama" }
    public var summary: String {
        "A local or self-hosted model. Runs on your own hardware, so nothing leaves your network."
    }
    public var isPrivate: Bool { true }

    /// Generous but not unbounded: context length depends on the model the
    /// reader pulled, and small local models degrade badly when the window is
    /// filled.
    public var contextBudgetChars: Int { 12000 }

    /// How long the status check and the model list wait: five seconds, as in
    /// Dart. Without it a host that accepts the connection and then stalls
    /// leaves the Test button in Settings spinning with no ceiling.
    static let probeTimeout: Duration = .seconds(5)

    public func checkStatus() async -> BackendStatus {
        if DartText.trimmed(host).isEmpty {
            return .unavailable("No Ollama host configured.")
        }
        guard await isReachable() else {
            return .unavailable("Could not reach Ollama at \(host). Check that it is running and, if it is on "
                + "another machine, that the address is correct.")
        }
        let models = await availableModels()
        if models.isEmpty {
            return .unavailable(
                "Ollama is running but has no models. Pull one, e.g. \"ollama pull llama3.2\".")
        }
        // No model chosen is a real "not ready", not a detail to paper over:
        // with an empty name the request would go out under whatever default
        // the client holds, which is how someone ends up querying a model they
        // never selected.
        if DartText.trimmed(model).isEmpty {
            return .unavailable("Connected to \(host), but no model is selected. Choose one from the list in "
                + "AI Backend settings.")
        }
        if !models.contains(where: { DartText.hasPrefix($0, model) }) {
            return .unavailable("Ollama is running but \"\(model)\" is not installed. Pull it or pick another model.")
        }
        return .available("Connected to \(host)")
    }

    /// The names of the models the host has pulled, from `/api/tags`. Empty
    /// when the host can't be reached or answers with anything unexpected,
    /// rather than throwing, as `getModels` does.
    public func availableModels() async -> [String] {
        guard let url = URL(string: "\(host)/api/tags") else { return [] }
        let response = try? await withTimeLimit(Self.probeTimeout) { [transport] in
            let response = try await transport.send(Self.request(url, timeout: Self.probeTimeout))
            return (response.statusCode, try await response.collect())
        }
        guard let response, response.0 == 200,
              let models = (try? OrderedJSON.parse(response.1))?["models"]?.arrayValue
        else { return [] }
        // Dart's `m['name'] as String` throws on a model without a name, and
        // its catch then returns no models at all.
        var names: [String] = []
        for entry in models {
            guard let name = entry["name"]?.stringValue else { return [] }
            names.append(name)
        }
        return names
    }

    /// Whether `/api/tags` answers 200 within five seconds (`isAvailable`).
    /// Public for the AI backend screen, which, as Flutter's `_test` does, tells
    /// "can't reach the host" apart from "reached it, but it has no models".
    public func isReachable() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        let status = try? await withTimeLimit(Self.probeTimeout) { [transport] in
            try await transport.send(Self.request(url, timeout: Self.probeTimeout)).statusCode
        }
        return status == 200
    }

    /// Load the model into memory ahead of the first question.
    ///
    /// The first `/api/generate` after choosing Ollama can take tens of seconds
    /// while the server loads a multi-gigabyte model, and during that silent
    /// gap the connection is liable to be reset. An empty-prompt request with
    /// a `keep_alive` makes this throwaway call pay the cold start, so the real
    /// question streams from a warm model. Best effort: any failure is
    /// swallowed, because the real request will still run and surface its own
    /// error if something is genuinely wrong. Gives up after five minutes.
    public func warmUp() async {
        guard let url = URL(string: "\(host)/api/generate") else { return }
        let body = OrderedJSON.object([
            ("model", .string(requestModel)),
            ("prompt", .string("")),
            ("stream", .bool(false)),
            // Resident long enough to cover a session's first few questions
            // without reloading.
            ("keep_alive", .string("30m")),
        ])
        _ = try? await withTimeLimit(.seconds(300)) { [transport] in
            _ = try await transport.send(Self.post(url, body: body, timeout: 300)).collect()
        }
    }

    /// Streams the answer from `/api/generate`, with reasoning removed.
    ///
    /// Filtered here as well as on the downloaded-model path: the reasoning
    /// models a reader is most likely to pull (`qwen3`, `deepseek-r1`) emit
    /// their chain of thought in `<think>` markers. A model that doesn't think
    /// out loud is unaffected.
    ///
    /// A connection dropped before the first token is retried, twice, after
    /// two and then four seconds: that is the signature of a cold model load
    /// resetting the socket, and once the model is resident the next attempt
    /// streams at once. Never once anything has streamed, so a mid-answer drop
    /// is never replayed as a duplicated answer.
    ///
    /// Failures: a non-200 reply is `InferenceError("Failed to generate:
    /// <status>")`, as Dart words it; an `{"error": …}` line in the stream is
    /// an `InferenceError` with Ollama's message (Dart skips these, see
    /// `ollamaLine`); a transport failure is passed through as the
    /// `URLError`, as Dart passes its `SocketException` through, so
    /// `ChatText.describe` can recognise a dropped connection.
    ///
    /// No overall timeout, as in Dart, where a cold load of a large model can
    /// legitimately keep the first byte waiting for minutes. The request's
    /// idle timeout is ten minutes; the chat screen's `Generation` has its own
    /// stall limit and Stop always works.
    public func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        ReasoningFilter.strip(rawStream(prompt: prompt, system: system))
    }

    /// The answer as Ollama streams it, before the reasoning filter.
    func rawStream(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        let body = OrderedJSON.object([
            ("model", .string(requestModel)),
            ("prompt", .string(prompt)),
            ("system", system.map(OrderedJSON.string) ?? .null),
            ("stream", .bool(true)),
            ("keep_alive", .string("30m")),
            ("options", .object([("temperature", .double(0.7))])),
        ])
        let url = URL(string: "\(host)/api/generate")
        let transport = transport
        let backoff = retryBackoff
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url else { throw InferenceError("\"\(host)\" is not a valid Ollama address.") }
                    let maxAttempts = 3
                    var attempt = 1
                    while true {
                        var streamedAnything = false
                        do {
                            let response = try await transport.send(Self.post(url, body: body, timeout: 600))
                            guard response.statusCode == 200 else {
                                throw InferenceError("Failed to generate: \(response.statusCode)")
                            }
                            var lines = LineAssembler()
                            var done = false
                            func handle(_ line: String) throws {
                                switch try Self.ollamaLine(line) {
                                case .piece(let piece):
                                    streamedAnything = true
                                    continuation.yield(piece)
                                case .done(let piece):
                                    if let piece {
                                        streamedAnything = true
                                        continuation.yield(piece)
                                    }
                                    done = true
                                case .skip:
                                    break
                                }
                            }
                            reading: for try await chunk in response.body {
                                for line in lines.feed(chunk) {
                                    try handle(line)
                                    if done { break reading }
                                }
                            }
                            if !done, let tail = lines.finish() { try handle(tail) }
                            // Ended, with or without an explicit done flag.
                            continuation.finish()
                            return
                        } catch {
                            let retriable = attempt < maxAttempts && !streamedAnything
                                && !Task.isCancelled && TransportFailure.isConnectionDrop(error)
                            guard retriable else { throw error }
                            try await Task.sleep(for: backoff * attempt)
                            attempt += 1
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The model name sent: the chosen one, or the client's default when none
    /// is chosen (`model.isEmpty ? null : model`).
    var requestModel: String { model.isEmpty ? Self.fallbackModel : model }

    enum Line: Equatable {
        case piece(String)
        /// The final object; it may carry a last piece.
        case done(String?)
        case skip
    }

    /// One NDJSON line of a streamed `/api/generate` reply.
    ///
    /// Blank lines and lines that aren't JSON objects are skipped, as in Dart:
    /// now that lines arrive whole, that only ever swallows genuine garbage.
    /// An object with an `error` string throws it as an `InferenceError`.
    /// Ollama sends one when generation fails after the reply has started
    /// (the model crashing or running out of memory mid-answer). The Dart
    /// code skips it, so the answer just stops and is stored as if complete;
    /// here the reader is told.
    static func ollamaLine(_ line: String) throws -> Line {
        guard !DartText.trimmed(line).isEmpty, let object = OrderedJSON.parse(line), object.isObject else {
            return .skip
        }
        if let message = object["error"]?.stringValue {
            throw InferenceError("Ollama: \(message)")
        }
        var piece: String?
        if let text = object["response"]?.stringValue, !text.isEmpty { piece = text }
        if object["done"]?.boolValue == true { return .done(piece) }
        return piece.map(Line.piece) ?? .skip
    }

    static func request(_ url: URL, timeout: Duration) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Double(timeout.components.seconds)
        return request
    }

    /// A JSON POST, with the content type package:http sends for a string
    /// body.
    static func post(_ url: URL, body: OrderedJSON, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.dartEncoded.utf8)
        request.timeoutInterval = timeout
        return request
    }
}

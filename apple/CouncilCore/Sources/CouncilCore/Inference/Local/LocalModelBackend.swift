// The downloaded on-device model as an answer source. Mirrors
// `LocalModelBackend` in lib/src/services/inference/local_model_backend.dart,
// with MLX in place of LiteRT-LM (apple/PLAN.md, Decisions).

import Foundation
import MLXLMCommon
import os

/// A small open-weights model the reader downloads once and then runs locally.
///
/// The floor for everyone the platform model doesn't reach: iPhones without
/// Apple Intelligence, readers who have it switched off, and Macs where they
/// want something other than Apple's model. It is not as good as Ollama on
/// real hardware or a frontier model behind an API key, and the picker says
/// so, but it is grounded generation with no account, no key and nothing
/// leaving the device.
///
/// Using it from the app:
///
///     let store = LocalModelStore(root: try LocalModelStore.defaultRoot())
///     let model = LocalModel.byID(storedID)        // or .recommendedHere()
///     for try await p in store.download(model) { progress = p.fraction }
///     let backend = LocalModelBackend(model: model, store: store)
///     for try await chunk in backend.generate(prompt: p, system: s) { ... }
///
/// When the reader picks another model, call `LocalModelRuntime.shared.unload()`
/// (or just start generating with the new one, which does it); to remove one,
/// `backend.delete()`.
public struct LocalModelBackend: InferenceBackend {
    public let model: LocalModel
    private let store: LocalModelStore
    private let runtime: LocalModelRuntime
    private let environment: LocalModelEnvironment
    private let deviceMemoryMB: @Sendable () -> Int?
    private let appAvailableMB: @Sendable () -> Int?

    /// - Parameters:
    ///   - environment, deviceMemoryMB, appAvailableMB: the device facts
    ///     `checkStatus` reads; injectable so every state can be tested on one
    ///     machine. The defaults read this device.
    public init(model: LocalModel,
                store: LocalModelStore,
                runtime: LocalModelRuntime = .shared,
                environment: LocalModelEnvironment = .current,
                deviceMemoryMB: @escaping @Sendable () -> Int? = LocalDeviceMemory.totalMB,
                appAvailableMB: @escaping @Sendable () -> Int? = LocalDeviceMemory.appAvailableMB) {
        self.model = model
        self.store = store
        self.runtime = runtime
        self.environment = environment
        self.deviceMemoryMB = deviceMemoryMB
        self.appAvailableMB = appAvailableMB
    }

    public var id: InferenceBackendID { .local }
    public var displayName: String { "Downloaded model" }
    public var summary: String {
        "A small open model kept on this device. One download, then it works offline with no account and no key."
    }
    public var isPrivate: Bool { true }
    public var contextBudgetChars: Int { model.contextBudgetChars }

    /// In order: can this device run MLX at all, does it have the memory for
    /// this model, is the model downloaded, and (on iOS, when it isn't already
    /// loaded) is there room to load it now.
    public func checkStatus() async -> BackendStatus {
        if let reason = environment.unsupportedReason {
            return .unavailable("\(reason) Ollama or an API key will work here.")
        }
        let platform = environment.platform
        let memory = deviceMemoryMB()
        if !model.fits(deviceMemoryMB: memory, on: platform) {
            let needed = model.requiredMB(on: platform)
            let detail = needed == Int.max
                ? "\(model.name) is too large to run on an iPhone or iPad. Choose a smaller model."
                : "\(model.name) needs a device with about \(Self.gigabytes(needed)) of memory, and this one has "
                    + "\(Self.gigabytes(memory ?? 0)). Choose a smaller model."
            return .unavailable(detail)
        }
        if !store.isDownloaded(model) {
            return .unavailable("\(model.name) is not downloaded yet. It is a \(model.approximateSize) one-time download.")
        }
        if await runtime.loadedModelID != model.id, let available = appAvailableMB(), available < model.ramMB {
            return .unavailable("There isn't enough free memory to load \(model.name) right now. "
                + "Close other apps and try again, or choose a smaller model.")
        }
        return .available("\(model.name), running on this device.")
    }

    public func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        let model = model
        let store = store
        let runtime = runtime
        let environment = environment
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Refused here as well as in checkStatus, because a backend
                    // chosen earlier is still the reader's stored setting, and
                    // otherwise it would be MLX that objects, in its own words,
                    // in the middle of an answer.
                    if let reason = environment.unsupportedReason {
                        throw InferenceError("\(reason) Ollama or an API key will work here.")
                    }
                    guard store.isDownloaded(model) else {
                        throw InferenceError("\(model.name) is not downloaded yet. Download it in Settings first.")
                    }

                    let container: ModelContainer
                    do {
                        container = try await runtime.container(for: model, in: store.directory(for: model))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw InferenceError("The downloaded model could not be loaded: \(error.localizedDescription)")
                    }

                    var messages: [Chat.Message] = []
                    if let system, !system.isEmpty { messages.append(.system(system)) }
                    messages.append(.user(prompt))
                    let input = try await container.prepare(
                        input: UserInput(chat: messages, additionalContext: Self.thinkingContext(for: model)))
                    let parameters = GenerateParameters(
                        maxTokens: model.answerTokenLimit(promptTokens: input.text.tokens.size),
                        temperature: Self.temperature)

                    let raw = Self.logRawOutput
                    for await event in try await container.generate(input: input, parameters: parameters) {
                        guard case .chunk(let text) = event else { continue }
                        if raw { Self.log.debug("raw chunk: \(text, privacy: .public)") }
                        continuation.yield(text)
                    }
                    // A cancelled consumer ends MLX's stream quietly; report it
                    // as a cancellation, not as a complete answer.
                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as InferenceError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: InferenceError(
                        "The downloaded model failed to answer: \(error.localizedDescription)"))
                }
            }
            // Cancelling the consumer cancels this task, which ends MLX's
            // stream, which cancels its generation loop before the next token.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The names of the models on offer on this device type.
    public func availableModels() async throws -> [String] {
        LocalModel.offered(on: environment.platform).map(\.name)
    }

    /// Deletes this backend's model, unloading it first (`uninstall`).
    public func delete() async throws {
        await runtime.unload(model)
        try await store.delete(model)
    }

    // MARK: - Generation settings

    /// Greedy decoding, as the Flutter app ran it: flutter_gemma's session
    /// defaults are temperature 0.8 with top-k 1, and top-k 1 always takes the
    /// most likely token whatever the temperature. MLX's equivalent is
    /// temperature 0 (its `ArgMaxSampler`). Qwen's own advice against greedy
    /// decoding concerns thinking mode, which is switched off here.
    static let temperature: Float = 0

    /// Template variables that switch Qwen3's thinking off.
    ///
    /// The Dart wanted the same and couldn't reach the template:
    /// flutter_gemma sends no `enable_thinking` hint at all, so it appended
    /// Qwen's soft switch, `/no_think`, to the prompt instead. Through MLX the
    /// template is ours to drive, and `enable_thinking: false` makes Qwen3's
    /// chat template open the answer with an empty `<think></think>` block:
    /// a hard switch where `/no_think` was a request a small model may
    /// ignore. Measured on the 0.6B in the Flutter app, three quarters of
    /// what it produced with thinking on was scratch work nobody would read.
    ///
    /// Only for models that think by default; the 2507 Instruct's template
    /// has no such variable. `ReasoningFilter` still runs downstream, as in
    /// the Dart, for whatever a model emits regardless.
    static func thinkingContext(for model: LocalModel) -> [String: any Sendable]? {
        model.thinksByDefault ? ["enable_thinking": false] : nil
    }

    // MARK: - Diagnostics

    /// Whether to log the raw token stream: set `COUNCIL_LOG_RAW_MODEL_OUTPUT=1`
    /// in the scheme's environment. Debug builds only. The Dart's
    /// `LOG_RAW_MODEL_OUTPUT`, kept because reasoning markers are invisible
    /// once rendered, so the transcript can't show what the model emitted.
    static var logRawOutput: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["COUNCIL_LOG_RAW_MODEL_OUTPUT"] == "1"
        #else
        false
        #endif
    }

    private static let log = Logger(subsystem: "site.spencersmith.council", category: "local_model")

    private static func gigabytes(_ mb: Int) -> String {
        String(format: "%.0f GB", (Double(mb) / 1024).rounded(.up))
    }
}

public extension LocalModel {
    /// Most tokens the answer may run to after a prompt of `promptTokens`.
    ///
    /// What is left of `maxTokens` once the prompt is in, as LiteRT-LM's KV
    /// cache size worked in the Flutter app; but never less than
    /// `minimumAnswerTokens`, so an unusually long prompt gets a short answer
    /// rather than none. LiteRT failed outright there; MLX has no hard limit
    /// at this size (Qwen3's trained context is 32K), so failing would be a
    /// choice, and not a helpful one.
    func answerTokenLimit(promptTokens: Int) -> Int {
        max(maxTokens - promptTokens, Self.minimumAnswerTokens)
    }

    static let minimumAnswerTokens = 256
}

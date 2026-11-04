// Holds the loaded model. Mirrors `_LocalModelRuntime` in
// lib/src/services/inference/local_model_backend.dart.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads a model once and keeps it.
///
/// Loading is expensive and the weights are large; doing it per question would
/// pay that cost on every message and risk two copies resident at once. So one
/// model at most is held, process-wide: asking for a different one releases
/// the first before loading the second, as the Dart's runtime does.
///
/// Also lets go under memory pressure. On iOS the alternative is the OS
/// killing the whole app, and the model is the one large thing that can be
/// reloaded on the next question without losing anything the reader can see.
public actor LocalModelRuntime {
    public static let shared = LocalModelRuntime()

    private var loaded: (id: String, container: ModelContainer)?
    /// A load in progress, so two questions asked at once share one load
    /// rather than reading the weights twice.
    private var loading: (id: String, task: Task<ModelContainer, any Error>)?
    private nonisolated let pressure: any DispatchSourceMemoryPressure

    init() {
        // Warning as well as critical on iOS, where the next step after a
        // warning is termination; on the Mac, critical only: a warning there
        // is routine and the system pages instead of killing the app.
        #if os(iOS)
        let events: DispatchSource.MemoryPressureEvent = [.warning, .critical]
        #else
        let events: DispatchSource.MemoryPressureEvent = [.critical]
        #endif
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: events, queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in
            Task { await self?.unload() }
        }
        pressure.activate()
    }

    deinit {
        pressure.cancel()
    }

    /// The id of the model held in memory, if any. For the UI ("loaded") and
    /// tests.
    public var loadedModelID: String? { loaded?.id }

    /// `model`'s container, loading it from `directory` if it isn't the one
    /// held. Releases any other model first.
    func container(for model: LocalModel, in directory: URL) async throws -> ModelContainer {
        if let loaded, loaded.id == model.id { return loaded.container }
        if let loading, loading.id == model.id { return try await loading.task.value }

        unload()
        let task = Task<ModelContainer, any Error> {
            #if os(iOS)
            // Bounds the buffers MLX keeps for reuse between steps, which
            // otherwise grow to Metal's recommended working set: a cost the
            // per-app memory cap on iOS can't absorb. mlx-swift's "Running on
            // iOS" article suggests 20 MB for LLMs.
            Memory.cacheLimit = 20 * 1_048_576
            #endif
            return try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        loading = (model.id, task)
        do {
            let container = try await task.value
            // Another model may have been asked for while this one loaded;
            // keep only what was asked for last.
            if loading?.id == model.id {
                loaded = (model.id, container)
                loading = nil
            }
            return container
        } catch {
            if loading?.id == model.id { loading = nil }
            throw error
        }
    }

    /// Releases the held model and MLX's buffer cache.
    ///
    /// A generation already running keeps its own reference and finishes; the
    /// memory is returned when it does. Call when the reader picks another
    /// model or deletes this one; called automatically under memory pressure.
    public func unload() {
        // Nothing held means MLX may never have started; touching its cache
        // would initialise Metal for nothing (and, in a SwiftPM test run with
        // no compiled shaders, fail).
        guard loaded != nil || loading != nil else { return }
        loaded = nil
        loading?.task.cancel()
        loading = nil
        Memory.clearCache()
    }

    /// Releases the held model if it is `model`. For deleting a model without
    /// disturbing a different one in use.
    public func unload(_ model: LocalModel) {
        if loaded?.id == model.id || loading?.id == model.id { unload() }
    }
}

/// Bridges swift-transformers' tokenizer to mlx-swift-lm's protocol.
///
/// mlx-swift-lm 3 takes the tokenizer as a protocol and offers this bridge
/// only as a macro (`#huggingFaceTokenizerLoader`, in MLXHuggingFace). It is
/// written out here instead: a dozen lines, and it keeps a compiler plugin
/// (and Xcode's macro trust prompt, and `-skipMacroValidation` in CI) out of
/// the build.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools,
                                                  additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

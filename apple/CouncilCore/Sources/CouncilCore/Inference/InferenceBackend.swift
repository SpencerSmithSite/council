// The contract every answer source meets. Mirrors `InferenceBackend` in
// lib/src/services/inference/inference_backend.dart.

import Foundation

/// A source of generated answers.
///
/// The app supports several, chosen by the reader: no model at all, Apple's
/// on-device Foundation Models, a downloaded MLX model, an Ollama server on the
/// local network, or a cloud provider the reader holds a key for. They differ
/// enough (in availability, in context size, and above all in whether anything
/// leaves the device) that those properties belong on the interface rather
/// than being assumed.
public protocol InferenceBackend: Sendable {
    /// Stable identifier, persisted in settings.
    var id: InferenceBackendID { get }

    /// Name shown in the backend picker.
    var displayName: String { get }

    /// One line describing what this backend is, for the picker.
    var summary: String { get }

    /// Whether answers are generated without anything leaving the device.
    ///
    /// Drives the privacy disclosure. The app is chosen partly for being
    /// offline-first, so a cloud backend must say so plainly rather than
    /// letting a blanket "everything is local" claim stand.
    var isPrivate: Bool { get }

    /// How much retrieved source text to include in a prompt, in characters
    /// (UTF-16 code units, as Dart counts them).
    ///
    /// Varies by an order of magnitude across backends: on-device models have
    /// small context windows, the cloud providers very large ones.
    var contextBudgetChars: Int { get }

    /// Whether this backend can serve a request now: Ollama reachable, key
    /// present, platform model ready. Cheap enough to call on screen load;
    /// implementations time out rather than hang.
    func checkStatus() async -> BackendStatus

    /// Streams an answer, chunk by chunk, as the model produces it. Finishes
    /// by throwing on failure: an `InferenceError` already worded for the
    /// reader, or a transport error (`URLError`) passed through so that
    /// `ChatText.describe` can recognise a dropped connection, as the Dart
    /// chat screen does. Cancelling the consuming task must stop generation
    /// (and close any connection) promptly; `Generation` drives this.
    func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error>

    /// Models offered by this backend, if it offers a choice.
    func availableModels() async throws -> [String]
}

public extension InferenceBackend {
    func availableModels() async throws -> [String] { [] }
}

/// The result of an availability check, with a reason when unavailable so the
/// UI can tell the reader what to fix rather than just greying something out.
public struct BackendStatus: Sendable, Hashable {
    public let available: Bool
    public let detail: String?

    public static func available(_ detail: String? = nil) -> BackendStatus {
        BackendStatus(available: true, detail: detail)
    }

    public static func unavailable(_ detail: String?) -> BackendStatus {
        BackendStatus(available: false, detail: detail)
    }
}

/// A failure the reader should see, already worded for them.
public struct InferenceError: LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The do-nothing backend: the app is a searchable library and nothing more.
///
/// The floor every device reaches, including ones too old for an on-device
/// model and readers who want no AI involved. A first-class choice, not a
/// failure state.
public struct RetrievalOnlyBackend: InferenceBackend {
    public init() {}

    public var id: InferenceBackendID { .none }
    public var displayName: String { "No AI (search only)" }
    public var summary: String {
        "Browse and search the library. No answers are generated and nothing leaves your device."
    }
    public var isPrivate: Bool { true }
    public var contextBudgetChars: Int { 0 }

    public func checkStatus() async -> BackendStatus { .available() }

    public func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: InferenceError(
                "Search-only mode is selected. Choose an AI backend in Settings to ask questions."))
        }
    }
}

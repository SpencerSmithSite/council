// Port of lib/src/services/inference/platform_llm_backend.dart, calling Apple's
// framework directly where the Flutter app went through the
// `FoundationModelsBridge` method and event channels
// (ios/Runner/FoundationModelsBridge.swift, whose wording and delta logic this
// keeps).

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the device's own model can't be used, when it can't.
///
/// A type rather than a string because the unavailable cases need different
/// treatment in the UI: two are fixable by the reader and one is not, and only
/// the unfixable ones should stop the option being offered at all. The raw
/// values are the Flutter enum's case names.
public enum PlatformLlmState: String, Sendable, CaseIterable {
    /// Ready to answer.
    case available
    /// The OS is too old for the framework to exist. Unreachable in this app,
    /// whose minimum is OS 26, but kept so the states match Flutter's.
    case osTooOld
    /// The framework exists but this hardware can't run the model.
    case notEligible
    /// Supported, but the reader hasn't switched Apple Intelligence on.
    case notEnabled
    /// Supported and enabled; the model is still downloading.
    case modelNotReady
    /// No framework on this platform, or a build without it.
    case unsupportedPlatform
    /// The framework reported something this version doesn't recognise.
    case unknown

    /// Whether to show this backend in the picker at all.
    ///
    /// A reader whose iPhone simply can't run Apple Intelligence isn't helped
    /// by a permanently greyed-out row; one who has merely left it switched
    /// off is, because the row tells them where the switch is.
    public var worthOffering: Bool {
        switch self {
        case .available, .notEnabled, .modelNotReady: true
        default: false
        }
    }
}

/// A snapshot of what the platform reported, with a sentence for the reader.
public struct PlatformLlmAvailability: Sendable, Hashable {
    public let state: PlatformLlmState
    public let detail: String

    public init(_ state: PlatformLlmState, _ detail: String) {
        self.state = state
        self.detail = detail
    }

    public var isAvailable: Bool { state == .available }
}

/// The language model built into the device: Apple's Foundation Models.
///
/// A model already on the device, with no key, no download and no network, so
/// the only generating backend besides a reader's own Ollama that keeps the
/// app's privacy claim intact: `isPrivate` is true.
///
/// Availability is asked of the framework, never inferred from an OS version.
/// Apple Intelligence needs particular silicon (an iPhone 15 Pro or newer, an
/// Apple-silicon Mac), so an OS 26 device can qualify while a newer OS on
/// older hardware can't, and only the framework can tell hardware that will
/// never support it from a switch the reader hasn't turned on.
///
/// Not cached, unlike the Dart `availability()`: there the answer cost a
/// platform-channel round trip, here it is a property read, so asking again
/// (on returning from Settings, say) is just asking.
public struct FoundationModelsBackend: InferenceBackend {
    let availabilityProvider: @Sendable () -> PlatformLlmAvailability

    /// `availability` stands in for the framework's answer, for tests and
    /// previews; leave it out to ask the device.
    public init(availability: (@Sendable () -> PlatformLlmAvailability)? = nil) {
        availabilityProvider = availability ?? { Self.systemAvailability() }
    }

    public var id: InferenceBackendID { .platform }
    public var displayName: String { "Apple Intelligence" }
    public var summary: String {
        "The model already on this device. No account, no key, no download, and nothing leaves it."
    }
    public var isPrivate: Bool { true }

    /// Deliberately small. Apple's on-device model has a context window of a
    /// few thousand tokens, an order of magnitude under the cloud backends, and
    /// overfilling it degrades the answer or fails it, so retrieval sends
    /// shorter passages here.
    public var contextBudgetChars: Int { 4000 }

    /// What the device reports now.
    public var availability: PlatformLlmAvailability { availabilityProvider() }

    public func checkStatus() async -> BackendStatus {
        let report = availability
        return report.isAvailable ? .available(report.detail) : .unavailable(report.detail)
    }

    /// Empty on purpose: the platform ships exactly one model and doesn't name
    /// it, so there is nothing for a model picker to offer.
    public func availableModels() async -> [String] { [] }

    /// Streams the answer from a fresh session whose instructions are
    /// `system`.
    ///
    /// The framework hands back the whole answer so far on each update rather
    /// than the newest fragment, so this sends the difference (`SnapshotDeltas`)
    /// or every piece would arrive with the entire answer prepended.
    /// Cancelling the consumer cancels the generation.
    public func generate(prompt: String, system: String?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            let task = Task {
                do {
                    let session = system.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
                    var deltas = SnapshotDeltas()
                    for try await snapshot in session.streamResponse(to: prompt) {
                        if Task.isCancelled { break }
                        if let delta = deltas.next(snapshot.content) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: InferenceError(Self.readable(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: InferenceError(Self.unsupportedDetail))
            #endif
        }
    }

    // MARK: - Availability

    /// The bridge's `availability()`, mapped as Dart's `fromReason` maps it.
    public static func systemAvailability() -> PlatformLlmAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return PlatformLlmAvailability(.available, "Apple Intelligence is ready on this device.")
        case .unavailable(let reason):
            return unavailable(reason)
        @unknown default:
            return PlatformLlmAvailability(
                .unknown, "Apple Intelligence reported a state this version of Council does not recognise.")
        }
        #else
        return PlatformLlmAvailability(.unsupportedPlatform, unsupportedDetail)
        #endif
    }

    static let unsupportedDetail = "This build of Council has no built-in model support."

    #if canImport(FoundationModels)
    /// Phrased as something the reader can act on. "Not eligible" is final and
    /// shouldn't read like a setting they failed to find; the other two are
    /// fixable and say how. The Settings app is named differently on each
    /// platform, and sending someone to the wrong one is worse than not naming
    /// it.
    static func unavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> PlatformLlmAvailability {
        switch reason {
        case .deviceNotEligible:
            #if os(macOS)
            return PlatformLlmAvailability(
                .notEligible, "This Mac does not support Apple Intelligence. It needs Apple silicon.")
            #else
            return PlatformLlmAvailability(
                .notEligible,
                "This iPhone does not support Apple Intelligence. It needs an iPhone 15 Pro or newer.")
            #endif
        case .appleIntelligenceNotEnabled:
            #if os(macOS)
            return PlatformLlmAvailability(
                .notEnabled,
                "Apple Intelligence is switched off. Turn it on in System Settings → Apple Intelligence & Siri.")
            #else
            return PlatformLlmAvailability(
                .notEnabled, "Apple Intelligence is switched off. Turn it on in Settings → Apple Intelligence & Siri.")
            #endif
        case .modelNotReady:
            return PlatformLlmAvailability(
                .modelNotReady,
                "Apple Intelligence is still downloading its model. This finishes on its own — try again shortly.")
        @unknown default:
            return PlatformLlmAvailability(.unknown, "Apple Intelligence is unavailable on this device.")
        }
    }

    // MARK: - Errors

    /// A generation failure in words the reader can act on.
    ///
    /// The two failures a RAG prompt is most likely to hit get sentences of
    /// their own; everything else is the framework's description, which is
    /// all the Flutter bridge ever passed on (`error.localizedDescription` for
    /// every failure).
    static func readable(_ error: any Error) -> String {
        if #available(iOS 27, macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return contextOverflow
                case .guardrailViolation: return guardrail
                default: break
                }
            }
        } else if let message = legacyReadable(error) {
            return message
        }
        return error.localizedDescription
    }

    static let contextOverflow = "The question and its sources are too long for Apple Intelligence. Ask a "
        + "shorter question, or choose a backend with more room in Settings."
    static let guardrail = "Apple Intelligence declined to answer this. Try rewording the question, or "
        + "choose a different backend in Settings."

    /// `GenerationError`, which OS 26 throws and OS 27 replaces with
    /// `LanguageModelError`. Marked deprecated itself so that naming the old
    /// type here isn't a warning; it is only called below OS 27.
    @available(iOS, introduced: 26.0, deprecated: 27.0)
    @available(macOS, introduced: 26.0, deprecated: 27.0)
    private static func legacyReadable(_ error: any Error) -> String? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize: return contextOverflow
        case .guardrailViolation: return guardrail
        default: return nil
        }
    }
    #endif
}

/// Turns a stream of cumulative snapshots ("The", "The Word", "The Word was")
/// into the pieces each one adds.
///
/// Compared by Unicode scalar rather than by `Character`, as the bridge did:
/// a combining mark arriving after its base letter changes a snapshot's
/// last character without changing the count of characters, so the bridge's
/// `whole.count > sent.count` skipped that snapshot and its `dropFirst(sent
/// .count)` later dropped the mark altogether. Scalars only ever grow.
///
/// A snapshot that doesn't extend the last one (the framework has never been
/// seen to revise, but nothing promises it won't) sends nothing, and later
/// snapshots are measured against it, so the rest of the answer still
/// arrives rather than everything after the revision being lost.
struct SnapshotDeltas {
    private var sent: [Unicode.Scalar] = []

    mutating func next(_ snapshot: String) -> String? {
        let scalars = Array(snapshot.unicodeScalars)
        guard scalars.starts(with: sent) else {
            sent = scalars
            return nil
        }
        guard scalars.count > sent.count else { return nil }
        var delta = String.UnicodeScalarView()
        delta.append(contentsOf: scalars[sent.count...])
        sent = scalars
        return String(delta)
    }
}

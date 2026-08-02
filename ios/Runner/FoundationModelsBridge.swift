import Flutter
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bridges Apple's on-device language model to Dart.
///
/// The framework arrived in iOS 26 and the app's deployment target is 15.0, so
/// every entry point is guarded twice: `canImport` so the app still compiles
/// against an older SDK, and `#available` so it still launches on an older OS.
/// Without both, adding this makes the app fail to build or fail to start for
/// everyone who cannot use it.
///
/// Availability is asked of the framework rather than inferred. A version check
/// is wrong in both directions — Apple Intelligence needs A17 Pro or newer
/// silicon, so an iOS 26 iPhone 15 Pro qualifies while an iOS 27 iPhone 14 does
/// not — and the framework's own `unavailable` reason is the only thing that
/// distinguishes "your device cannot" from "you have not switched it on", which
/// are different problems for the reader to fix.
enum FoundationModelsBridge {
    private static let methodChannelName = "site.spencersmith.council/platform_llm"
    private static let eventChannelName = "site.spencersmith.council/platform_llm_stream"

    static func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: methodChannelName, binaryMessenger: registrar.messenger())
        methods.setMethodCallHandler { call, result in
            switch call.method {
            case "availability":
                result(availability())
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        let events = FlutterEventChannel(
            name: eventChannelName, binaryMessenger: registrar.messenger())
        events.setStreamHandler(GenerationStreamHandler())
    }

    /// `{supported, available, reason, detail}` — `supported` is whether the OS
    /// has the framework at all, `available` whether it will answer right now.
    static func availability() -> [String: Any] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return [
                    "supported": true,
                    "available": true,
                    "reason": "available",
                    "detail": "Apple Intelligence is ready on this device.",
                ]
            case .unavailable(let reason):
                return [
                    "supported": true,
                    "available": false,
                    "reason": describe(reason),
                    "detail": explain(reason),
                ]
            @unknown default:
                return [
                    "supported": true,
                    "available": false,
                    "reason": "unknown",
                    "detail": "Apple Intelligence reported a state this version "
                        + "of Council does not recognise.",
                ]
            }
        }
        #endif
        return [
            "supported": false,
            "available": false,
            "reason": "os_too_old",
            "detail": "Apple's on-device model needs iOS 26 or later.",
        ]
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: return "device_not_eligible"
        case .appleIntelligenceNotEnabled: return "not_enabled"
        case .modelNotReady: return "model_not_ready"
        @unknown default: return "unknown"
        }
    }

    /// Phrased as something the reader can act on. "Not eligible" is final and
    /// should not read like a setting they failed to find; the other two are
    /// fixable and should say how.
    @available(iOS 26.0, *)
    private static func explain(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This iPhone does not support Apple Intelligence. It needs "
                + "an iPhone 15 Pro or newer."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is switched off. Turn it on in Settings "
                + "\u{2192} Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. This "
                + "finishes on its own \u{2014} try again shortly."
        @unknown default:
            return "Apple Intelligence is unavailable on this device."
        }
    }
    #endif
}

/// Streams one generation at a time.
///
/// Tokens arrive as events and the stream closes on completion, which maps onto
/// Dart's `Stream<String>` without the caller having to reassemble anything.
/// The framework hands back the whole answer so far on each update rather than
/// the newest fragment, so this sends the delta — otherwise every token would
/// arrive with the entire answer prepended and the UI would repeat itself.
final class GenerationStreamHandler: NSObject, FlutterStreamHandler {
    private var task: Task<Void, Never>?

    func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        guard let args = arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
            return FlutterError(
                code: "bad_arguments", message: "prompt is required", details: nil)
        }
        let system = args["system"] as? String

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            task = Task {
                do {
                    let session = system.map { LanguageModelSession(instructions: $0) }
                        ?? LanguageModelSession()
                    var sent = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        if Task.isCancelled { break }
                        let whole = partial.content
                        guard whole.count > sent.count else { continue }
                        let delta = String(whole.dropFirst(sent.count))
                        sent = whole
                        await MainActor.run { events(delta) }
                    }
                    await MainActor.run { events(FlutterEndOfEventStream) }
                } catch {
                    await MainActor.run {
                        events(FlutterError(
                            code: "generation_failed",
                            message: error.localizedDescription,
                            details: nil))
                        events(FlutterEndOfEventStream)
                    }
                }
            }
            return nil
        }
        #endif

        events(FlutterError(
            code: "unsupported",
            message: "Apple's on-device model needs iOS 26 or later.",
            details: nil))
        events(FlutterEndOfEventStream)
        return nil
    }

    /// Cancels in flight. Dart cancelling its subscription — the reader leaving
    /// the screen mid-answer — must stop the work, not leave it running.
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        task?.cancel()
        task = nil
        return nil
    }
}

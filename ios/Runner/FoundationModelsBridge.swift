#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bridges Apple's on-device language model to Dart.
///
/// Shared by the iOS and macOS runners — one file referenced from both Xcode
/// projects rather than two copies, because the framework, the availability
/// rules and the channel contract are identical and a divergence between them
/// would be invisible until one platform silently stopped offering the model.
/// Only the Flutter module name differs.
///
/// The framework arrived in iOS 26 / macOS 26 and the deployment targets are
/// older, so every entry point is guarded twice: `canImport` so the app still
/// compiles against an older SDK, and `#available` so it still launches on an
/// older OS. Without both, adding this makes the app fail to build or fail to
/// start for everyone who cannot use it.
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
        // `messenger` is a method on iOS and a property on macOS. Resolved once
        // here so the two channel constructions below read identically.
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif

        let methods = FlutterMethodChannel(
            name: methodChannelName, binaryMessenger: messenger)
        methods.setMethodCallHandler { call, result in
            switch call.method {
            case "availability":
                result(availability())
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        let events = FlutterEventChannel(
            name: eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(GenerationStreamHandler())
    }

    /// `{supported, available, reason, detail}` — `supported` is whether the OS
    /// has the framework at all, `available` whether it will answer right now.
    static func availability() -> [String: Any] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
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
            "detail": Self.tooOldDetail,
        ]
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
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
    @available(iOS 26.0, macOS 26.0, *)
    private static func explain(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            #if os(macOS)
            return "This Mac does not support Apple Intelligence. It needs "
                + "Apple silicon."
            #else
            return "This iPhone does not support Apple Intelligence. It needs "
                + "an iPhone 15 Pro or newer."
            #endif
        case .appleIntelligenceNotEnabled:
            // The settings app is named differently on each platform, and
            // sending someone to the wrong one is worse than not naming it.
            #if os(macOS)
            return "Apple Intelligence is switched off. Turn it on in System "
                + "Settings \u{2192} Apple Intelligence & Siri."
            #else
            return "Apple Intelligence is switched off. Turn it on in Settings "
                + "\u{2192} Apple Intelligence & Siri."
            #endif
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. This "
                + "finishes on its own \u{2014} try again shortly."
        @unknown default:
            return "Apple Intelligence is unavailable on this device."
        }
    }
    #endif

    /// Named once, because it is returned from both the availability check and
    /// the generation stream.
    static var tooOldDetail: String {
        #if os(macOS)
        return "Apple's on-device model needs macOS 26 or later."
        #else
        return "Apple's on-device model needs iOS 26 or later."
        #endif
    }
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
        if #available(iOS 26.0, macOS 26.0, *) {
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
            message: FoundationModelsBridge.tooOldDetail,
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

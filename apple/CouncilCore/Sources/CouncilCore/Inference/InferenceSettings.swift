// Port of the preference half of lib/src/services/inference/inference_provider.dart:
// its keys, defaults and setters, the opening-backend rule (`_openingBackend`,
// test/inference_default_backend_test.dart) and the `backend` getter that
// turns the settings into a backend.

import Foundation

/// The reader's choice of AI backend and its configuration.
///
/// Ordinary preferences in `UserDefaults`, under the Flutter app's own key
/// names and encodings, unprefixed (Phase 7 copies `flutter.<key>` across;
/// see `FlutterPreferences`). Cloud API keys are not here: they are the
/// reader's own credentials and live in the Keychain (`SecretStore`).
///
/// | Key | Type | Default | Notes |
/// |---|---|---|---|
/// | `inference_backend` | `String` | see `openingBackend` | An `InferenceBackendID` raw value; an unknown one reads as `none` |
/// | `ollama_host` | `String` | `http://localhost:11434` | Trimmed when set |
/// | `ollama_model` | `String` | empty | Trimmed when set; blank on purpose (`OllamaBackend.defaultModel`) |
/// | `cloud_provider` | `String` | `anthropic` | A `CloudProvider` raw value; an unknown one reads as `anthropic` |
/// | `cloud_model` | `String` | the provider's `defaultModel` | Reset to the new provider's default when the provider changes |
/// | `local_model` | `String` | none stored | The downloaded model's id; unset means "whatever the catalogue recommends for this device" |
/// | `has_onboarded` | `Bool` | false | Read only, by `openingBackend`; the onboarding flow owns it |
///
/// Each property reads `UserDefaults` directly (no cached copy, so two
/// instances never disagree); an `@Observable` model in the app wraps it for
/// SwiftUI, as `ReaderPreferences` is wrapped.
///
/// `Sendable` although `UserDefaults` isn't marked so: `UserDefaults` is
/// documented as thread-safe, and this holds nothing else.
public struct InferenceSettings: Sendable {
    public enum Key {
        public static let backend = "inference_backend"
        public static let ollamaHost = "ollama_host"
        public static let ollamaModel = "ollama_model"
        public static let cloudProvider = "cloud_provider"
        public static let cloudModel = "cloud_model"
        public static let localModel = "local_model"
        /// Owned by onboarding (Flutter's `SettingsService`); read here, as
        /// the Dart reads it directly rather than ordering one load after the
        /// other.
        public static let hasOnboarded = "has_onboarded"
    }

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Backend

    /// The stored choice, or nil if the reader has never had one. An id this
    /// build doesn't know (written by a later one, say) reads as `.none`, as
    /// the Dart `backend` getter falls back to search-only.
    public var storedBackend: InferenceBackendID? {
        guard let raw = defaults.object(forKey: Key.backend) as? String else { return nil }
        return InferenceBackendID(rawValue: raw) ?? InferenceBackendID.none
    }

    public func setBackend(_ id: InferenceBackendID) {
        defaults.set(id.rawValue, forKey: Key.backend)
    }

    /// The backend to use: the stored choice, or, for a reader who has never
    /// chosen, the opening one (written back).
    ///
    /// `platformModelReady` is whether Apple Intelligence can answer right now
    /// (`FoundationModelsBackend().availability.isAvailable`), and
    /// `localModelSupported` whether this device can run a downloaded model at
    /// all (the MLX catalogue's own check). Passed in so the rule can be tested
    /// without either.
    ///
    /// Search-only used to be the opening choice, which meant onboarding
    /// opened on the app's least capable setting and every reader who wanted
    /// an answer had to go and find the option that gives one. The two private
    /// backends are better openings and cost nothing to preselect: the
    /// device's own model when it can answer right now (installed, no account,
    /// no key, nothing leaving the device), and otherwise the local download,
    /// the same bargain one step further away. Neither downloads anything by
    /// being selected. Failing both, search-only stands.
    ///
    /// Ready rather than merely offered: the picker shows an Apple
    /// Intelligence row that is only switched off, since the row says where
    /// the switch is, but starting a reader on a backend that can't answer yet
    /// is worse than starting them on the download.
    ///
    /// Written back, because a default the reader was shown and left alone is
    /// a choice and has to survive the launch after onboarding, and a default
    /// that re-derived itself each launch would move under them as
    /// availability changed.
    ///
    /// Only for a reader who hasn't been through onboarding. An install with
    /// no stored backend but onboarding behind it has already been offered
    /// this choice and left it at search-only; switching a model on now
    /// wouldn't be a default, it would be changing their mind for them. That
    /// case returns `.none` without writing it, as in Dart.
    public func resolveBackend(platformModelReady: Bool, localModelSupported: Bool) -> InferenceBackendID {
        if let stored = storedBackend { return stored }
        if defaults.bool(forKey: Key.hasOnboarded) { return .none }
        let id: InferenceBackendID = platformModelReady ? .platform : localModelSupported ? .local : .none
        setBackend(id)
        return id
    }

    // MARK: - Ollama

    public var ollamaHost: String {
        (defaults.object(forKey: Key.ollamaHost) as? String) ?? OllamaBackend.defaultHost
    }

    public var ollamaModel: String {
        (defaults.object(forKey: Key.ollamaModel) as? String) ?? OllamaBackend.defaultModel
    }

    /// Sets either or both, trimmed. Both keys are written, as Dart's
    /// `setOllama` writes both.
    public func setOllama(host: String? = nil, model: String? = nil) {
        let newHost = host.map(DartText.trimmed) ?? ollamaHost
        let newModel = model.map(DartText.trimmed) ?? ollamaModel
        defaults.set(newHost, forKey: Key.ollamaHost)
        defaults.set(newModel, forKey: Key.ollamaModel)
    }

    // MARK: - Cloud

    public var cloudProvider: CloudProvider {
        CloudProvider(id: (defaults.object(forKey: Key.cloudProvider) as? String) ?? CloudProvider.anthropic.id)
    }

    public var cloudModel: String {
        (defaults.object(forKey: Key.cloudModel) as? String) ?? cloudProvider.defaultModel
    }

    /// Switches provider and resets the model to the new provider's default:
    /// a Claude model name means nothing to Gemini.
    public func setCloudProvider(_ provider: CloudProvider) {
        defaults.set(provider.id, forKey: Key.cloudProvider)
        defaults.set(provider.defaultModel, forKey: Key.cloudModel)
    }

    public func setCloudModel(_ model: String) {
        defaults.set(model, forKey: Key.cloudModel)
    }

    // MARK: - Local model

    /// The chosen downloaded model's id, or nil when the reader hasn't chosen.
    ///
    /// Unset means "recommend one": Flutter computes the recommendation from
    /// what the device can hold on every launch and doesn't store it, so an
    /// explicit pick (including a smaller model than the device could manage)
    /// is kept while an unmade choice follows the hardware. The MLX catalogue
    /// owns that recommendation.
    public var localModelID: String? {
        defaults.object(forKey: Key.localModel) as? String
    }

    public func setLocalModel(_ id: String) {
        defaults.set(id, forKey: Key.localModel)
    }

    // MARK: - Building the backend

    /// The backend `id` stands for, configured from these settings: Dart's
    /// `InferenceProvider.backend`, constructed fresh so configuration edits
    /// always take effect.
    ///
    /// `local` is built by `makeLocal`, given `localModelID`, because the MLX
    /// backend lives with its model catalogue. The cloud key is read from
    /// `secrets` now; a key that can't be read counts as no key (the backend
    /// then reports itself unavailable and says to add one).
    public func backend(for id: InferenceBackendID, secrets: any SecretStore,
                        transport: any HTTPTransport = URLSessionTransport(),
                        makeLocal: (_ modelID: String?) -> any InferenceBackend) -> any InferenceBackend {
        switch id {
        case .none:
            return RetrievalOnlyBackend()
        case .platform:
            return FoundationModelsBackend()
        case .local:
            return makeLocal(localModelID)
        case .ollama:
            return OllamaBackend(host: ollamaHost, model: ollamaModel, transport: transport)
        case .cloud:
            let provider = cloudProvider
            return CloudBackend(provider: provider, model: cloudModel, apiKey: secrets.apiKey(for: provider),
                                transport: transport)
        }
    }
}

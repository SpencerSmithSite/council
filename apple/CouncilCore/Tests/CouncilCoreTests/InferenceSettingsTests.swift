// Covers Inference/InferenceSettings.swift and Inference/SecretStore.swift.
// The opening-backend cases are test/inference_default_backend_test.dart's;
// the rest are the keys, defaults and setters of inference_provider.dart.

import Foundation
import Testing
@testable import CouncilCore

/// A `UserDefaults` suite of its own, removed afterwards.
final class ScratchDefaults {
    let name = "InferenceSettingsTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init(_ values: [String: Any] = [:]) {
        defaults = UserDefaults(suiteName: name)!
        for (key, value) in values { defaults.set(value, forKey: key) }
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite struct InferenceSettingsTests {
    // MARK: Which backend a reader who has never chosen one starts on

    @Test func aDeviceWithABuiltInModelOpensOnIt() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.resolveBackend(platformModelReady: true, localModelSupported: true) == .platform)
    }

    @Test func aDeviceWithoutOneOpensOnTheLocalDownload() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.resolveBackend(platformModelReady: false, localModelSupported: true) == .local)
    }

    /// With no built-in model and no local engine there is nothing to lead
    /// with.
    @Test func aDeviceThatCanRunNeitherStaysOnSearchOnly() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.resolveBackend(platformModelReady: false, localModelSupported: false) == .none)
        #expect(settings.storedBackend == InferenceBackendID.none, "written back like the others")
    }

    /// Before the choice was written back, this is where it was lost: the
    /// reader saw the built-in model selected, never touched the row, and the
    /// next launch had them on search-only.
    @Test func theOpeningChoiceSurvivesTheLaunchAfterOnboarding() {
        let scratch = ScratchDefaults()
        _ = InferenceSettings(defaults: scratch.defaults).resolveBackend(platformModelReady: true,
                                                                         localModelSupported: true)
        scratch.defaults.set(true, forKey: InferenceSettings.Key.hasOnboarded)
        let relaunched = InferenceSettings(defaults: scratch.defaults)
        #expect(relaunched.resolveBackend(platformModelReady: false, localModelSupported: false) == .platform)
    }

    /// Someone past onboarding has been offered this choice and left it; a
    /// model switched on for them now would be changing their mind.
    @Test func anInstallAlreadyPastOnboardingIsLeftOnSearchOnly() {
        let scratch = ScratchDefaults([InferenceSettings.Key.hasOnboarded: true])
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.resolveBackend(platformModelReady: true, localModelSupported: true) == .none)
        #expect(settings.storedBackend == nil, "not written, as in Dart")
    }

    @Test func aStoredChoiceIsNeverOverridden() {
        let scratch = ScratchDefaults([InferenceSettings.Key.backend: "none"])
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.resolveBackend(platformModelReady: true, localModelSupported: true) == .none)
    }

    @Test func anUnknownStoredIdReadsAsSearchOnly() {
        let scratch = ScratchDefaults([InferenceSettings.Key.backend: "litert-next"])
        #expect(InferenceSettings(defaults: scratch.defaults).storedBackend == InferenceBackendID.none)
    }

    // MARK: Keys and defaults

    @Test func defaultsAreFlutters() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.storedBackend == nil)
        #expect(settings.ollamaHost == "http://localhost:11434")
        #expect(settings.ollamaModel == "")
        #expect(settings.cloudProvider == .anthropic)
        #expect(settings.cloudModel == "claude-opus-4-8")
        #expect(settings.localModelID == nil)
    }

    /// What the Flutter app would have stored, read under the same keys.
    @Test func valuesStoredUnderFluttersKeysAreRead() {
        let scratch = ScratchDefaults([
            "inference_backend": "cloud", "ollama_host": "http://mac.local:11434", "ollama_model": "qwen3:8b",
            "cloud_provider": "gemini", "cloud_model": "gemini-1.5-pro", "local_model": "qwen3-1.7b",
        ])
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.storedBackend == .cloud)
        #expect(settings.ollamaHost == "http://mac.local:11434")
        #expect(settings.ollamaModel == "qwen3:8b")
        #expect(settings.cloudProvider == .gemini)
        #expect(settings.cloudModel == "gemini-1.5-pro")
        #expect(settings.localModelID == "qwen3-1.7b")
    }

    @Test func anUnknownProviderReadsAsAnthropic() {
        let scratch = ScratchDefaults(["cloud_provider": "mistral"])
        let settings = InferenceSettings(defaults: scratch.defaults)
        #expect(settings.cloudProvider == .anthropic)
        #expect(settings.cloudModel == "claude-opus-4-8")
    }

    @Test func settingOllamaTrimsAndWritesBoth() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        settings.setOllama(host: "  http://10.0.0.2:11434 \n")
        #expect(scratch.defaults.string(forKey: "ollama_host") == "http://10.0.0.2:11434")
        #expect(scratch.defaults.string(forKey: "ollama_model") == "")
        settings.setOllama(model: " llama3.2 ")
        #expect(settings.ollamaHost == "http://10.0.0.2:11434")
        #expect(settings.ollamaModel == "llama3.2")
    }

    /// A Claude model name means nothing to Gemini.
    @Test func changingProviderResetsTheModel() {
        let scratch = ScratchDefaults()
        let settings = InferenceSettings(defaults: scratch.defaults)
        settings.setCloudModel("claude-haiku-4-5")
        settings.setCloudProvider(.openai)
        #expect(scratch.defaults.string(forKey: "cloud_provider") == "openai")
        #expect(settings.cloudModel == "gpt-4o")
    }

    @Test func backendsAreBuiltFromTheSettings() {
        let scratch = ScratchDefaults(["ollama_host": "http://h:1", "ollama_model": "m", "cloud_provider": "xai",
                                       "local_model": "qwen3-0.6b"])
        let settings = InferenceSettings(defaults: scratch.defaults)
        let secrets = InMemorySecretStore(["xai": "xai-key"])
        var askedFor: String?
        let make = { (id: InferenceBackendID) in
            settings.backend(for: id, secrets: secrets, transport: FakeTransport(.body(""))) { modelID in
                askedFor = modelID
                return RetrievalOnlyBackend()
            }
        }
        #expect(make(.none) is RetrievalOnlyBackend)
        #expect(make(.platform) is FoundationModelsBackend)
        let ollama = make(.ollama) as? OllamaBackend
        #expect(ollama?.host == "http://h:1")
        #expect(ollama?.model == "m")
        let cloud = make(.cloud) as? CloudBackend
        #expect(cloud?.provider == .xai)
        #expect(cloud?.model == "grok-2-latest")
        #expect(cloud?.apiKey == "xai-key")
        _ = make(.local)
        #expect(askedFor == "qwen3-0.6b")
    }
}

@Suite struct SecretStoreTests {
    static let keychainUsable: Bool = {
        let probe = KeychainSecretStore(service: "site.spencersmith.council.tests.probe")
        guard (try? probe.setSecret("probe", for: "probe")) != nil else { return false }
        try? probe.setSecret(nil, for: "probe")
        return true
    }()

    @Test func keysAreSavedTrimmedAndDeletedWhenEmpty() throws {
        let store = InMemorySecretStore()
        #expect(store.apiKey(for: .anthropic) == "")
        try store.setAPIKey("  sk-ant-1\n", for: .anthropic)
        #expect(store.apiKey(for: .anthropic) == "sk-ant-1")
        #expect(try store.secret(for: "anthropic") == "sk-ant-1", "the account is the provider id")
        #expect(store.apiKey(for: .openai) == "", "one key per provider")
        try store.setAPIKey("   ", for: .anthropic)
        #expect(try store.secret(for: "anthropic") == nil)
    }

    /// A Keychain that can't be read (locked, or an unsigned test binary
    /// without the entitlement) is "no key", as in Dart.
    @Test func anUnreadableStoreMeansNoKey() {
        struct Locked: SecretStore {
            func secret(for account: String) throws -> String? { throw KeychainError(status: -25308) }
            func setSecret(_ value: String?, for account: String) throws {}
        }
        #expect(Locked().apiKey(for: .gemini) == "")
    }

    @Test func fluttersKeychainNamesAreRecordedForMigration() {
        #expect(KeychainSecretStore.flutterService == "flutter_secure_storage_service")
        #expect(CloudProvider.allCases.map(KeychainSecretStore.flutterAccount(for:))
            == ["api_key_anthropic", "api_key_openai", "api_key_gemini", "api_key_xai"])
        #expect(KeychainSecretStore().service == "site.spencersmith.council.cloud")
    }

    /// The real Keychain round trip, under a throwaway service. On the Mac
    /// this is the login keychain and runs anywhere it is unlocked; on iOS
    /// the data-protection keychain refuses an unsigned binary
    /// (errSecMissingEntitlement), which skips this test rather than failing
    /// it.
    @Test(.enabled(if: Self.keychainUsable, "needs a signed binary with a keychain entitlement"))
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "site.spencersmith.council.tests.\(UUID().uuidString)")
        try store.setSecret("v1", for: "anthropic")
        defer { try? store.setSecret(nil, for: "anthropic") }
        #expect(try store.secret(for: "anthropic") == "v1")
        try store.setSecret("v2", for: "anthropic")
        #expect(try store.secret(for: "anthropic") == "v2")
        try store.setSecret(nil, for: "anthropic")
        #expect(try store.secret(for: "anthropic") == nil)
        try store.setSecret(nil, for: "anthropic")
    }
}

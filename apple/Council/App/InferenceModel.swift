import CouncilCore
import Foundation
import Observation
import os

/// The app's side of CouncilCore's `Inference/`: which backend answers
/// questions, whether it can right now, and whether using it sends anything
/// off the device. The native counterpart of Flutter's `InferenceProvider`
/// (lib/src/services/inference/inference_provider.dart), minus the
/// preference storage, which `InferenceSettings` already owns.
///
/// One per process, owned by `AppModel` (`model.inference`), because the
/// backend choice is a property of the install, not of a window: two Mac
/// windows asking questions use the same model, and the AI backend screen
/// (Phase 5, built later) changes it for all of them at once.
///
/// What it holds, and why each piece lives here:
///
/// - `settings`, the reader's choice and its configuration, in `UserDefaults`
///   under Flutter's keys. Read fresh each time the backend is rebuilt, so an
///   edit always takes effect.
/// - `secrets`, the Keychain, where cloud API keys live.
/// - `localModels`, the one `LocalModelStore` for the downloaded MLX models.
///   One store per root is the store's own rule (it refuses a second
///   download of a model by tracking them), so the backend built here and
///   the backend screen's download and delete buttons must share it.
/// - `platformAvailability`, what Apple Intelligence reports. Asked again by
///   `refreshStatus`, since the reader can switch it on in Settings and come
///   back.
/// - `backend`, the resolved current backend, and `status`, its last
///   `checkStatus()`.
///
/// The backend is rebuilt by `reload()`, which runs on its own whenever one
/// of the inference keys changes in `UserDefaults`; the Keychain sends no
/// such notice, so whatever changes a cloud key calls `reload()` itself.
///
/// Main-actor because the UI observes it. Nothing slow runs there: the
/// status checks are the backends' own async work (network for Ollama and the
/// cloud, file and memory checks for MLX), which CouncilCore runs off the
/// caller's actor.
@Observable @MainActor
final class InferenceModel {
    let settings: InferenceSettings
    let secrets: any SecretStore
    /// The downloaded models' store, shared with the AI backend screen.
    let localModels: LocalModelStore

    /// What Apple Intelligence last reported.
    private(set) var platformAvailability: PlatformLlmAvailability
    /// The backend questions go to.
    private(set) var backend: any InferenceBackend = RetrievalOnlyBackend()
    /// The last availability check of `backend`, or nil while the first is
    /// running (and briefly after each `reload`).
    private(set) var status: BackendStatus?

    /// Whether asking a question sends it, and the passages retrieved for it,
    /// to someone else's computer. Drives the privacy line under the
    /// composer: the app is chosen for being offline-first, so a cloud
    /// backend must say so where the question is typed (Flutter's
    /// `sendsDataOffDevice`).
    var sendsDataOffDevice: Bool { !backend.isPrivate }

    /// Bumped by every rebuild, so a status check that finishes after the
    /// backend changed doesn't overwrite the new backend's status.
    private var revision = 0
    private var started = false
    /// The inference keys' values when the backend was last built, so the
    /// defaults notification (which fires for every key the app writes, the
    /// reading position on each scroll included) only rebuilds when one of
    /// ours changed.
    private var fingerprint: [String?] = []
    private var defaultsObserver: (any NSObjectProtocol)?

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Inference")

    init(settings: InferenceSettings = InferenceSettings(),
         secrets: any SecretStore = KeychainSecretStore()) {
        self.settings = settings
        self.secrets = secrets
        // `defaultRoot` only fails when Application Support can't be
        // resolved, in which case the corpus has failed too and nothing is
        // asked; the temporary directory just keeps the type non-optional.
        let root = (try? LocalModelStore.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appending(path: "MLXModels", directoryHint: .isDirectory)
        localModels = LocalModelStore(root: root)
        platformAvailability = FoundationModelsBackend.systemAvailability()
    }

    /// Resolves the opening backend and starts watching the settings.
    ///
    /// As Flutter's `load`: the platform model's availability first, then the
    /// stored choice, or for a reader who has never chosen, the opening one
    /// (`InferenceSettings.resolveBackend`, which writes it back), then a
    /// status check. Only the first call does anything.
    func start() {
        guard !started else { return }
        started = true
        platformAvailability = FoundationModelsBackend.systemAvailability()
        _ = settings.resolveBackend(platformModelReady: platformAvailability.isAvailable,
                                    localModelSupported: LocalModelEnvironment.current.unsupportedReason == nil)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
        reload()
    }

    /// Rebuilds the backend from the settings as they are now, and checks it.
    ///
    /// Call after changing anything `UserDefaults` doesn't announce (a cloud
    /// key in the Keychain). Changes to the inference keys themselves call it
    /// on their own.
    func reload() {
        fingerprint = currentFingerprint()
        let id = settings.storedBackend ?? .none
        backend = settings.backend(for: id, secrets: secrets, makeLocal: { [localModels] modelID in
            // An unset choice follows the hardware: the catalogue's
            // recommendation for this device, as Flutter computes it on every
            // launch without storing it.
            LocalModelBackend(model: modelID.map { LocalModel.byID($0) } ?? LocalModel.recommendedHere(),
                              store: localModels)
        })
        revision += 1
        status = nil
        Task { await refreshStatus() }
    }

    /// Asks the current backend whether it can answer now, and Apple
    /// Intelligence what state it is in. Called on start, after every rebuild,
    /// and whenever the Ask tab appears.
    ///
    /// When Ollama turns out to be reachable, its model is loaded ahead of the
    /// first question (`warmUp`), as Flutter's `refreshStatus` does: a cold
    /// load of a large model is what otherwise times out the first answer.
    func refreshStatus() async {
        platformAvailability = FoundationModelsBackend.systemAvailability()
        let checked = backend
        let revision = revision
        let result = await checked.checkStatus()
        guard revision == self.revision else { return }
        status = result
        if !result.available {
            Self.logger.info("\(checked.displayName, privacy: .public) unavailable: \(result.detail ?? "", privacy: .public)")
        }
        if result.available, let ollama = checked as? OllamaBackend {
            // Detached from the screen: the warm-up outlives whichever view
            // asked for the status, and its result is deliberately ignored.
            Task.detached { await ollama.warmUp() }
        }
    }

    // MARK: - Watching the settings

    private func settingsMayHaveChanged() {
        if currentFingerprint() != fingerprint { reload() }
    }

    private func currentFingerprint() -> [String?] {
        [settings.storedBackend?.rawValue, settings.ollamaHost, settings.ollamaModel,
         settings.cloudProvider.id, settings.cloudModel, settings.localModelID]
    }
}

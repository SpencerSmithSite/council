import CouncilCore
import Foundation
import Observation

/// Whether to show first-run setup, and the collections it set downloading.
///
/// One per process, on `AppModel` (`model.onboarding`), because both things
/// outlive the sheet: every Mac window presents the same onboarding and
/// dismisses it together, and a collection chosen in onboarding keeps
/// installing after the reader has started reading.
///
/// ## Who sees it
///
/// Flutter shows `OnboardingScreen` while `has_onboarded` is false
/// (lib/main.dart, `SettingsService.getHasOnboarded`), deliberately on the
/// flag rather than on an empty library, so a reader who removed everything
/// isn't walked through setup again. Same key here, unprefixed, as
/// `InferenceSettings.Key.hasOnboarded` already reads it. Someone the Flutter
/// app onboarded must not see it either, so a reader counts as onboarded when
/// any of these holds:
///
/// 1. `has_onboarded` is true: this app's own flag.
/// 2. `flutter.has_onboarded` is true: the Flutter app's flag, which
///    shared_preferences keeps in `UserDefaults.standard` with a `flutter.`
///    prefix. On iPhone and iPad the native app installs over the Flutter one
///    with the same bundle id, so this is already readable; on the Mac it is
///    readable once Phase 7 copies the sandboxed preferences out.
/// 3. The library holds the reader's own data (`ExistingInstall`): a
///    highlight, note or conversation in `council_user.db`, or an installed
///    collection. Flutter only lets those exist past onboarding, so they
///    stand in for a flag this app can't see: the Mac before Phase 7's copy
///    (as long as the copy runs before `decide`), a native build from before
///    onboarding existed, or a Flutter install interrupted between
///    onboarding's install and its `completeOnboarding()`.
///
/// 1 and 2 are read synchronously in `init`, so an onboarded reader never
/// waits on anything. 3 reads two SQLite files and runs in `decide`, which
/// `AppModel.start` calls before it opens either file. Whenever 2 or 3
/// decides it, `has_onboarded` is written, so the decision is made once and
/// `InferenceSettings`' opening-backend rule (which reads the same key) sees
/// an existing reader as one.
@Observable @MainActor
final class OnboardingGate {
    enum Decision: Equatable {
        /// The library check hasn't run yet. Nothing is shown meanwhile.
        case undecided
        case needed
        case notNeeded
    }

    /// One chosen collection's install, as the download step shows it.
    enum InstallState: Equatable {
        case waiting
        case installing
        case installed
        case failed(String)
    }

    private(set) var decision: Decision
    /// Whether the onboarding sheet is up, in every window.
    var isPresented = false

    /// The collections handed over by `install(_:with:)`, in order.
    private(set) var queued: [PackCollection] = []
    private(set) var installs: [String: InstallState] = [:]
    /// True while any of `queued` is still waiting or installing.
    var isInstalling: Bool {
        installs.values.contains { $0 == .waiting || $0 == .installing }
    }

    @ObservationIgnored private var installTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private static let key = InferenceSettings.Key.hasOnboarded
    private static let flutterKey = FlutterPreferences.defaultsKey(InferenceSettings.Key.hasOnboarded)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: Self.key) {
            decision = .notNeeded
        } else if defaults.bool(forKey: Self.flutterKey) {
            decision = .notNeeded
            defaults.set(true, forKey: Self.key)
        } else {
            decision = .undecided
        }
    }

    /// Settles a reader the flags didn't, from the library in
    /// `supportDirectory`, and presents onboarding if they're new.
    ///
    /// Call before anything opens `council_user.db` or the corpus, so the
    /// read can't race the app creating, migrating or reinstalling them. A nil
    /// directory (Application Support couldn't be resolved, so the corpus is
    /// failing too) leaves it undecided: there is nothing to set up then.
    func decide(supportDirectory: URL?) async {
        guard decision == .undecided, let supportDirectory else { return }
        if await Self.hasReaderData(in: supportDirectory) {
            defaults.set(true, forKey: Self.key)
            decision = .notNeeded
        } else {
            decision = .needed
            isPresented = true
        }
    }

    /// Records `has_onboarded`. Called when the reader commits (Skip, or Get
    /// Started), not when the sheet goes: Flutter records it after its
    /// downloads, because its screen stays up until they finish, but here the
    /// downloads belong to `PackLibrary` and carry on without the sheet, so
    /// the reader is through setup as soon as they've chosen.
    func markOnboarded() {
        defaults.set(true, forKey: Self.key)
        decision = .notNeeded
    }

    /// Closes onboarding in every window, recording it if it wasn't already.
    func finish() {
        markOnboarded()
        isPresented = false
    }

    /// Shows onboarding again, for Settings' "Show Onboarding" (Flutter's
    /// settings_screen.dart pushes `OnboardingScreen` from there).
    func replay() {
        isPresented = true
    }

    // MARK: - Installing what was chosen

    /// Installs `collections` one after another, in the background, through
    /// `library`.
    ///
    /// As Flutter's `_finish(download: true)`: collected across the steps and
    /// installed in manifest order at the end, so the reader saw the total
    /// before committing. Unlike Flutter the queue isn't tied to the screen:
    /// it lives here, so "Start Reading" can close onboarding while it runs.
    ///
    /// `PackLibrary` runs one install at a time and silently ignores a second,
    /// so each collection waits for any install another screen started (the
    /// Ask tab's coverage notice, Browse) rather than being dropped.
    func install(_ collections: [PackCollection], with library: PackLibrary) {
        // Anything already queued or installed by an earlier run (onboarding
        // shown again from Settings) isn't queued twice; a failure is retried.
        let new = collections.filter { collection in
            switch installs[collection.id] {
            case nil, .failed: true
            default: false
            }
        }
        guard !new.isEmpty else { return }
        for collection in new {
            if !queued.contains(where: { $0.id == collection.id }) { queued.append(collection) }
            installs[collection.id] = .waiting
        }
        // After whatever an earlier call queued, so installs never overlap.
        let previous = installTask
        installTask = Task { [weak self] in
            await previous?.value
            for collection in new {
                while library.busyID != nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                self?.installs[collection.id] = .installing
                await library.install(collection)
                self?.installs[collection.id] = library.installed.contains(collection.id)
                    ? .installed
                    : .failed(library.error ?? String(localized: "The download didn’t finish."))
            }
        }
    }

    // `@concurrent`: two SQLite opens, kept off the main actor that the app
    // target's approachable concurrency would otherwise run them on.
    @concurrent
    private nonisolated static func hasReaderData(in directory: URL) async -> Bool {
        ExistingInstall.hasReaderData(in: directory)
    }
}

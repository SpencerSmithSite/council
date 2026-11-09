// apple/PLAN.md, Phase 7: what the native app takes over from a Flutter
// install it replaces. Same bundle id, so the data is already on the device;
// this finds it and makes it this app's.

import Foundation
import os

/// Where a Flutter install of Council kept what the native app carries over.
///
/// On iPhone and iPad the native app is installed over the Flutter one into
/// the same app container, so the library is already where this app looks,
/// and the preferences are the `flutter.`-prefixed keys of this app's own
/// `UserDefaults`. On the Mac the Flutter app was sandboxed
/// (macos/Runner/Release.entitlements) and this one is not, so everything of
/// Flutter's is inside `~/Library/Containers/<bundle id>/Data`, where the
/// sandbox redirected its home directory.
public struct FlutterInstall: Sendable {
    /// Flutter's `getApplicationSupportDirectory()`: the corpus, `packs/` and
    /// `council_user.db`.
    public var supportDirectory: URL
    /// The preferences file, when Flutter's preferences aren't in this app's
    /// own `UserDefaults` (the Mac's container). Nil reads the `flutter.` keys
    /// from the defaults the migration writes to.
    public var preferencesFile: URL?
    /// Where flutter_gemma kept downloaded models.
    public var modelDirectories: [URL]
    /// `flutter_secure_storage`'s items: its default service, in the
    /// data-protection keychain on both platforms (see `KeychainSecretStore`).
    public var secrets: any SecretStore

    public init(supportDirectory: URL, preferencesFile: URL?, modelDirectories: [URL], secrets: any SecretStore) {
        self.supportDirectory = supportDirectory
        self.preferencesFile = preferencesFile
        self.modelDirectories = modelDirectories
        self.secrets = secrets
    }

    /// The install this device would have, given this app's own
    /// Application Support directory (`AppModel.supportDirectory`).
    ///
    /// Paths follow path_provider_foundation 2.6.0 (Application Support as is
    /// on iOS, plus the bundle id on macOS) and flutter_gemma 1.4.2's
    /// `_getDocumentsDirectory` (Documents on iOS; `flutter_gemma/` in
    /// Application Support on macOS, with Documents as its legacy location).
    public static func current(supportDirectory: URL,
                               bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "site.spencersmith.council")
        -> FlutterInstall {
        let secrets = KeychainSecretStore(service: KeychainSecretStore.flutterService, usesDataProtectionKeychain: true)
        #if os(macOS)
        let container = URL.homeDirectory.appending(path: "Library/Containers/\(bundleIdentifier)/Data",
                                                    directoryHint: .isDirectory)
        let support = container.appending(path: "Library/Application Support/\(bundleIdentifier)",
                                          directoryHint: .isDirectory)
        return FlutterInstall(
            supportDirectory: support,
            preferencesFile: container.appending(path: "Library/Preferences/\(bundleIdentifier).plist"),
            modelDirectories: [support.appending(path: "flutter_gemma", directoryHint: .isDirectory),
                               container.appending(path: "Documents", directoryHint: .isDirectory)],
            secrets: secrets)
        #else
        return FlutterInstall(supportDirectory: supportDirectory, preferencesFile: nil,
                              modelDirectories: [URL.documentsDirectory], secrets: secrets)
        #endif
    }
}

/// Carries a Flutter install's preferences, cloud keys, library and old model
/// files over to this app, once.
///
/// In two halves, because they have to run at different moments:
///
/// - `migrateSettings()`, synchronous and quick: the preferences and the cloud
///   keys. Run it before anything reads `UserDefaults` (the theme, the reading
///   style and the onboarding gate all read it as the app starts), so the
///   first frame is already in the reader's theme.
/// - `migrateFiles()`: the Mac's copy of the library out of the container,
///   and deleting flutter_gemma's models. Run it off the main actor, before
///   the onboarding gate's library check and before anything opens the corpus
///   or the user database.
///
/// Each step is recorded in `completedStepsKey` when it is finished and is
/// never run again, so a reader who changes or resets a setting afterwards
/// never has it brought back. A step that couldn't finish (a locked iPhone's
/// Keychain, a container macOS wouldn't open) stays unrecorded and is tried at
/// the next launch.
///
/// Flutter's own copies are left as they are: its `flutter.` keys, its
/// Keychain items and, on the Mac, its container. They cost almost nothing,
/// and nothing reads them once their step is recorded.
public struct FlutterMigration {
    public enum Step: String, CaseIterable, Sendable {
        case preferences, keychain, files, models
    }

    /// What a run found that the reader should be told about.
    public struct Outcome: Equatable, Sendable {
        public enum LibraryProblem: Equatable, Sendable {
            /// The Flutter app's container is there but macOS wouldn't let
            /// this app read it.
            case unreadable
            /// Reading worked and copying didn't.
            case copyFailed(String)
        }

        public var library: LibraryProblem?
        /// The provider whose key the Flutter app was using and that couldn't
        /// be read, so the reader has to enter it again.
        public var keyToReenter: CloudProvider?
        /// Bytes of flutter_gemma models deleted. MLX can't read them.
        public var removedModelBytes: Int64 = 0

        public init(library: LibraryProblem? = nil, keyToReenter: CloudProvider? = nil, removedModelBytes: Int64 = 0) {
            self.library = library
            self.keyToReenter = keyToReenter
            self.removedModelBytes = removedModelBytes
        }

        public mutating func merge(_ other: Outcome) {
            library = other.library ?? library
            keyToReenter = other.keyToReenter ?? keyToReenter
            removedModelBytes += other.removedModelBytes
        }
    }

    /// The steps finished, as an array of `Step` raw values.
    public static let completedStepsKey = "flutter_migration_done"
    /// Set while the library copy is part done, so a copy cut short is redone
    /// rather than mistaken for this app's own library.
    static let copyInProgressKey = "flutter_migration_copying"

    /// The preferences carried over: every key the Flutter app wrote that this
    /// app reads, under the same name and encoding. Left out on purpose:
    /// `recently_viewed` (Flutter deletes it itself) and the legacy theme keys
    /// `dark_mode` and `theme_choice`, which `legacyTheme` turns into
    /// `theme_mode` and `theme_id` as Dart's `SettingsService` reads them.
    public static let carriedKeys: Set<String> = [
        ThemePreferenceKeys.mode,
        ThemePreferenceKeys.themeID,
        ReaderPreferences.Key.fontSize,
        AppSettings.showCitationsKey,
        AppSettings.autoCheckUpdatesKey,
        InferenceSettings.Key.hasOnboarded,
        BookmarkStore.key,
        ShelfStore.pinnedKey,
        ShelfStore.starredKey,
        ShelfStore.collapsedKey,
        ShelfStore.arrangedKey,
        InferenceSettings.Key.backend,
        InferenceSettings.Key.ollamaHost,
        InferenceSettings.Key.ollamaModel,
        InferenceSettings.Key.cloudProvider,
        InferenceSettings.Key.cloudModel,
        InferenceSettings.Key.localModel,
    ]
    /// Per-work reading positions, `reading_position_<source id>`.
    public static let carriedKeyPrefix = "reading_position_"

    /// The library's files and folders in Application Support, both apps'
    /// names. The two databases take their SQLite sidecars with them.
    static let libraryItems = [UserDatabase.fileName, CorpusConstants.databaseFileName,
                               CorpusConstants.stampFileName, PackService.workspaceDirectoryName]
    static let sqliteSidecars = ["-wal", "-shm", "-journal"]

    /// Every model file the Flutter app ever offered (lib/src/services/
    /// inference/local_model_backend.dart and its history): the LiteRT-LM
    /// builds of the four Qwen 3 models, and the MediaPipe `.task` files of
    /// the models before them. Named rather than matched by extension, so
    /// nothing else in Documents is touched.
    public static let flutterModelFiles: Set<String> = [
        "qwen3_0_6b_mixed_int4.litertlm",
        "Qwen3_1.7B.litertlm",
        "qwen3_4b_instruct_2507_mixed_int4.litertlm",
        "qwen3_8b_mixed_int4.litertlm",
        "gemma3-1b-it-q4.task",
        "gemma3-270m-it-q8.task",
        "Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task",
    ]

    public let install: FlutterInstall
    /// This app's Application Support directory.
    public let supportDirectory: URL
    public let defaults: UserDefaults
    /// This app's cloud keys.
    public let secrets: any SecretStore

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Migration")

    public init(install: FlutterInstall, supportDirectory: URL, defaults: UserDefaults = .standard,
                secrets: any SecretStore = KeychainSecretStore()) {
        self.install = install
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        self.secrets = secrets
    }

    public var completedSteps: Set<Step> {
        Set((defaults.stringArray(forKey: Self.completedStepsKey) ?? []).compactMap(Step.init(rawValue:)))
    }

    /// Records `step` as finished without running it: the reader's "Start
    /// Fresh" when the old library can't be read.
    public func skip(_ step: Step) {
        complete(step)
    }

    private func complete(_ step: Step) {
        let done = completedSteps.union([step]).map(\.rawValue).sorted()
        defaults.set(done, forKey: Self.completedStepsKey)
    }

    // MARK: - Settings

    /// The preferences, then the cloud keys. Quick and synchronous: see the
    /// type's documentation for when to call it.
    public func migrateSettings() -> Outcome {
        var outcome = Outcome()
        let done = completedSteps
        // Read once: the key step needs the backend and provider the reader
        // had in Flutter, whatever this app's defaults hold by then.
        let flutter = flutterPreferences()
        if !done.contains(.preferences) {
            switch flutter {
            case .found(let preferences):
                carry(preferences)
                complete(.preferences)
            case .absent:
                complete(.preferences)
            case .unreadable:
                outcome.library = .unreadable
            }
        }
        if !done.contains(.keychain) {
            switch flutter {
            case .found(let preferences):
                if let key = migrateKeys(usingProvider: preferences) { outcome.keyToReenter = key }
            case .absent:
                complete(.keychain)
            case .unreadable:
                // Which key was in use is in the preferences we couldn't
                // read; try again with them next launch.
                break
            }
        }
        return outcome
    }

    enum PreferenceRead {
        /// Keys without the `flutter.` prefix.
        case found([String: Any])
        case absent
        case unreadable
    }

    func flutterPreferences() -> PreferenceRead {
        let prefixed: [String: Any]
        if let file = install.preferencesFile {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                if Self.isMissing(error) { return .absent }
                Self.logger.error("Flutter preferences unreadable: \(String(describing: error), privacy: .public)")
                return .unreadable
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                Self.logger.error("Flutter preferences aren't a property list; leaving them")
                return .absent
            }
            prefixed = plist
        } else {
            prefixed = defaults.dictionaryRepresentation()
        }
        let prefix = FlutterPreferences.keyPrefix
        var preferences: [String: Any] = [:]
        for (key, value) in prefixed where key.hasPrefix(prefix) {
            preferences[String(key.dropFirst(prefix.count))] = value
        }
        return preferences.isEmpty ? .absent : .found(preferences)
    }

    /// Copies each carried key this app hasn't set itself. "Not set" rather
    /// than overwriting, because the one thing that can have written a key
    /// before this runs is this app, deliberately: the onboarding gate copies
    /// `has_onboarded` from Flutter's flag as it starts.
    func carry(_ preferences: [String: Any]) {
        for (key, value) in preferences
        where Self.carriedKeys.contains(key) || key.hasPrefix(Self.carriedKeyPrefix) {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
        let legacy = Self.legacyTheme(preferences)
        if defaults.object(forKey: ThemePreferenceKeys.mode) == nil, let mode = legacy.mode {
            defaults.set(mode, forKey: ThemePreferenceKeys.mode)
        }
        if defaults.object(forKey: ThemePreferenceKeys.themeID) == nil, let id = legacy.themeID {
            defaults.set(id, forKey: ThemePreferenceKeys.themeID)
        }
    }

    /// `SettingsService.getThemeMode` and `getThemeId` for an install that
    /// still has only the keys before them: `theme_choice`, whose
    /// `catppuccinMocha` was a dark theme and is now the `catppuccin` palette,
    /// and before that the `dark_mode` bool.
    static func legacyTheme(_ preferences: [String: Any]) -> (mode: String?, themeID: String?) {
        let choice = preferences["theme_choice"] as? String
        var mode = preferences[ThemePreferenceKeys.mode] as? String
        if mode == nil {
            if let choice {
                mode = switch choice {
                case "light", "dark": choice
                case "catppuccinMocha": "dark"
                default: "system"
                }
            } else if let dark = preferences["dark_mode"] as? Bool {
                mode = dark ? "dark" : "light"
            }
        }
        var themeID = preferences[ThemePreferenceKeys.themeID] as? String
        if themeID == nil, choice == "catppuccinMocha" {
            themeID = "catppuccin"
        }
        return (mode, themeID)
    }

    /// Re-saves every provider's Flutter key under this app's service, unless
    /// this app already has one for it. Returns the provider the reader was
    /// using when its key couldn't be read at all.
    ///
    /// On the Mac the read fails outright: the Flutter app's items are in the
    /// data-protection keychain, which this unsandboxed app has no entitlement
    /// for (`errSecMissingEntitlement`). That is the case to tell the reader
    /// about, but only for the provider they had chosen: the other keys were
    /// never being used. On iOS a read fails only while the device is locked
    /// (the items are `WhenUnlocked`), and the step waits for the next launch.
    func migrateKeys(usingProvider preferences: [String: Any]) -> CloudProvider? {
        let inUse = (preferences[InferenceSettings.Key.backend] as? String) == InferenceBackendID.cloud.rawValue
            ? CloudProvider(id: (preferences[InferenceSettings.Key.cloudProvider] as? String) ?? "")
            : nil
        var unreadable: [CloudProvider] = []
        for provider in CloudProvider.allCases {
            guard secrets.apiKey(for: provider).isEmpty else { continue }
            let key: String?
            do {
                key = try install.secrets.secret(for: KeychainSecretStore.flutterAccount(for: provider))
            } catch {
                Self.logger.error("Flutter key for \(provider.id, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
                unreadable.append(provider)
                continue
            }
            guard let key, !key.isEmpty else { continue }
            do {
                try secrets.setAPIKey(key, for: provider)
            } catch {
                Self.logger.error("Couldn't save the \(provider.id, privacy: .public) key: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        if unreadable.isEmpty {
            complete(.keychain)
            return nil
        }
        if Self.retriesUnreadableKeys { return nil }
        complete(.keychain)
        return inUse.flatMap { unreadable.contains($0) ? $0 : nil }
    }

    /// Whether an unreadable Flutter key is worth trying again next launch:
    /// on iOS it means a locked device, on the Mac a keychain this app can
    /// never open.
    static var retriesUnreadableKeys: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    // MARK: - Files

    /// The Mac's library copy, then the old models. Touches the disk: run it
    /// off the main actor, and before anything opens the corpus or the user
    /// database (see the type's documentation).
    public func migrateFiles() -> Outcome {
        var outcome = Outcome()
        let done = completedSteps
        if !done.contains(.files) {
            if let problem = copyLibrary() {
                outcome.library = problem
            } else {
                complete(.files)
            }
        }
        if !done.contains(.models) {
            let (removed, finished) = removeFlutterModels()
            outcome.removedModelBytes = removed
            if finished { complete(.models) }
        }
        return outcome
    }

    /// Copies the Flutter app's library into this app's Application Support,
    /// replacing what this app has there, when the two are different places
    /// (the Mac). Returns what went wrong, or nil when the step is finished.
    ///
    /// Copies only a Flutter library that holds the reader's own data, and only
    /// over one that doesn't (`ExistingInstall`): someone who has used this
    /// app already has a library of its own, which a copy would destroy, and a
    /// Flutter library with nothing of the reader's in it is only the corpus,
    /// which this app installs itself.
    func copyLibrary() -> Outcome.LibraryProblem? {
        let source = install.supportDirectory
        guard source.standardizedFileURL != supportDirectory.standardizedFileURL else { return nil }
        let fm = FileManager.default
        let present: Set<String>
        do {
            present = Set(try fm.contentsOfDirectory(atPath: source.path))
        } catch {
            if Self.isMissing(error) { return nil }
            Self.logger.error("Flutter library unreadable: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        let resuming = defaults.bool(forKey: Self.copyInProgressKey)
        if !resuming {
            guard ExistingInstall.hasReaderData(in: source) else { return nil }
            if ExistingInstall.hasReaderData(in: supportDirectory) {
                Self.logger.notice("This app already has a library; leaving the Flutter one where it is")
                return nil
            }
        }
        defaults.set(true, forKey: Self.copyInProgressKey)
        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            for item in Self.libraryItems where present.contains(item) {
                // A database's sidecars go with it, and this app's are removed
                // even when Flutter's has none: a WAL left beside a replaced
                // database would be replayed into it.
                let names = [item] + (item.hasSuffix(".db") ? Self.sqliteSidecars.map { item + $0 } : [])
                for name in names {
                    let target = supportDirectory.appending(path: name)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                }
                for name in names where present.contains(name) {
                    // copyItem clones on APFS, so the corpus costs no space
                    // until one copy changes.
                    try fm.copyItem(at: source.appending(path: name), to: supportDirectory.appending(path: name))
                }
            }
        } catch {
            Self.logger.error("Copying the Flutter library failed: \(String(describing: error), privacy: .public)")
            return .copyFailed(error.localizedDescription)
        }
        defaults.removeObject(forKey: Self.copyInProgressKey)
        return nil
    }

    /// Deletes flutter_gemma's models. Returns the bytes freed, and whether
    /// every model directory could be looked in (the Mac's are in the
    /// container, which may not open).
    func removeFlutterModels() -> (removed: Int64, finished: Bool) {
        let fm = FileManager.default
        var removed: Int64 = 0
        var finished = true
        for directory in install.modelDirectories {
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: directory.path)
            } catch {
                if !Self.isMissing(error) { finished = false }
                continue
            }
            for name in names where Self.flutterModelFiles.contains(name) {
                let file = directory.appending(path: name)
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                do {
                    try fm.removeItem(at: file)
                    removed += size
                } catch {
                    Self.logger.error("Couldn't delete \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                    finished = false
                }
            }
        }
        return (removed, finished)
    }

    /// Whether `error` means the file isn't there, as opposed to being there
    /// and unreadable.
    static func isMissing(_ error: any Error) -> Bool {
        var error: NSError? = error as NSError
        while let current = error {
            switch (current.domain, current.code) {
            case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError),
                 (NSPOSIXErrorDomain, Int(ENOENT)):
                return true
            default:
                error = current.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return false
    }
}

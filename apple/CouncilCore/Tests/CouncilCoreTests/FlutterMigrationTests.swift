// Covers Migration/FlutterMigration.swift: a Flutter install's preferences,
// cloud keys, library and models carried over to the native app.

import Foundation
import GRDB
import Testing
@testable import CouncilCore

@Suite final class FlutterMigrationTests {
    let root: URL
    /// This app's Application Support directory.
    let support: URL
    /// The Flutter app's, as on the Mac: somewhere else.
    let flutterSupport: URL
    let models: URL
    let defaults: UserDefaults
    let suiteName = "council-migration-\(UUID().uuidString)"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "council-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        support = root.appending(path: "native", directoryHint: .isDirectory)
        flutterSupport = root.appending(path: "flutter", directoryHint: .isDirectory)
        models = root.appending(path: "Documents", directoryHint: .isDirectory)
        for directory in [support, flutterSupport, models] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// An install laid out as on iPhone: the library in place, the preferences
    /// in this app's defaults.
    private func phone(flutterSecrets: any SecretStore = InMemorySecretStore(),
                       secrets: any SecretStore = InMemorySecretStore()) -> FlutterMigration {
        FlutterMigration(
            install: FlutterInstall(supportDirectory: support, preferencesFile: nil,
                                    modelDirectories: [models], secrets: flutterSecrets),
            supportDirectory: support, defaults: defaults, secrets: secrets)
    }

    /// An install laid out as on the Mac: everything in the container.
    private func mac(preferences: URL? = nil, flutterSecrets: any SecretStore = InMemorySecretStore(),
                     secrets: any SecretStore = InMemorySecretStore()) -> FlutterMigration {
        FlutterMigration(
            install: FlutterInstall(supportDirectory: flutterSupport,
                                    preferencesFile: preferences ?? root.appending(path: "flutter.plist"),
                                    modelDirectories: [models], secrets: flutterSecrets),
            supportDirectory: support, defaults: defaults, secrets: secrets)
    }

    private func setFlutter(_ values: [String: Any]) {
        for (key, value) in values { defaults.set(value, forKey: FlutterPreferences.defaultsKey(key)) }
    }

    private func writePlist(_ values: [String: Any]) throws -> URL {
        let file = root.appending(path: "flutter.plist")
        let prefixed = Dictionary(uniqueKeysWithValues: values.map { (FlutterPreferences.defaultsKey($0.key), $0.value) })
        try PropertyListSerialization.data(fromPropertyList: prefixed, format: .binary, options: 0).write(to: file)
        return file
    }

    // MARK: - Preferences

    @Test func carriesTheFlutterKeysUnprefixed() {
        setFlutter([
            "theme_id": "gruvbox", "theme_mode": "dark", "font_size": 1.2, "show_citations": false,
            "has_onboarded": true, "bookmarks": "[]", "shelf_pinned_sources": ["3", "7"],
            "reading_position_42": 5, "inference_backend": "ollama", "ollama_host": "http://mac.local:11434",
            "local_model": "qwen3-1.7b",
        ])
        let outcome = phone().migrateSettings()
        #expect(outcome == FlutterMigration.Outcome())
        #expect(defaults.string(forKey: "theme_id") == "gruvbox")
        #expect(defaults.string(forKey: "theme_mode") == "dark")
        #expect(defaults.double(forKey: "font_size") == 1.2)
        #expect(defaults.object(forKey: "show_citations") as? Bool == false)
        #expect(defaults.bool(forKey: "has_onboarded"))
        #expect(defaults.stringArray(forKey: "shelf_pinned_sources") == ["3", "7"])
        #expect(ReadingPositionStore(defaults: defaults).position(forSource: 42) == 5)
        #expect(InferenceSettings(defaults: defaults).storedBackend == .ollama)
        #expect(defaults.string(forKey: "ollama_host") == "http://mac.local:11434")
        #expect(defaults.string(forKey: "local_model") == "qwen3-1.7b")
        #expect(phone().completedSteps == [.preferences, .keychain])
    }

    @Test func leavesKeysThisAppDoesNotRead() {
        setFlutter(["recently_viewed": "[1,2]", "dark_mode": true, "something_else": 1])
        _ = phone().migrateSettings()
        #expect(defaults.object(forKey: "recently_viewed") == nil)
        #expect(defaults.object(forKey: "dark_mode") == nil)
        #expect(defaults.object(forKey: "something_else") == nil)
    }

    @Test func neverOverwritesWhatThisAppSet() {
        setFlutter(["has_onboarded": false, "theme_id": "nord"])
        defaults.set(true, forKey: "has_onboarded")
        _ = phone().migrateSettings()
        #expect(defaults.bool(forKey: "has_onboarded"))
        #expect(defaults.string(forKey: "theme_id") == "nord")
    }

    /// Once recorded, a setting the reader then resets stays reset.
    @Test func runsOnce() {
        setFlutter(["theme_id": "nord"])
        _ = phone().migrateSettings()
        defaults.removeObject(forKey: "theme_id")
        _ = phone().migrateSettings()
        #expect(defaults.object(forKey: "theme_id") == nil)
    }

    @Test func noFlutterInstallFinishesAtOnce() {
        #expect(phone().migrateSettings() == FlutterMigration.Outcome())
        #expect(phone().completedSteps == [.preferences, .keychain])
    }

    @Test(arguments: [
        (["theme_choice": "catppuccinMocha"], "dark", "catppuccin"),
        (["theme_choice": "light"], "light", nil),
        (["theme_choice": "sepia"], "system", nil),
        (["dark_mode": true], "dark", nil),
        (["dark_mode": false], "light", nil),
        // The string keys win over the legacy ones, as in Dart.
        (["theme_mode": "light", "theme_choice": "catppuccinMocha"], "light", "catppuccin"),
    ] as [([String: any Sendable], String?, String?)])
    func legacyThemeKeys(_ stored: [String: any Sendable], mode: String?, themeID: String?) {
        setFlutter(stored)
        _ = phone().migrateSettings()
        #expect(defaults.string(forKey: ThemePreferenceKeys.mode) == mode)
        #expect(defaults.string(forKey: ThemePreferenceKeys.themeID) == themeID)
    }

    @Test func readsTheMacContainersPreferencesFile() throws {
        let file = try writePlist(["theme_id": "dracula", "auto_check_updates": false])
        _ = mac(preferences: file).migrateSettings()
        #expect(defaults.string(forKey: "theme_id") == "dracula")
        #expect(defaults.object(forKey: "auto_check_updates") as? Bool == false)
    }

    @Test func anUnreadablePreferencesFileIsReportedAndRetried() throws {
        let file = try writePlist(["theme_id": "dracula"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let outcome = mac(preferences: file).migrateSettings()
        #expect(outcome.library == .unreadable)
        #expect(mac(preferences: file).completedSteps.isEmpty)
        #expect(defaults.object(forKey: "theme_id") == nil)
    }

    // MARK: - Keys

    @Test func carriesEveryProvidersKey() {
        setFlutter(["inference_backend": "cloud", "cloud_provider": "openai"])
        let flutter = InMemorySecretStore(["api_key_anthropic": "sk-ant", "api_key_openai": "sk-oai",
                                           "api_key_gemini": "old-gemini"])
        let secrets = InMemorySecretStore(["gemini": "mine"])
        let outcome = phone(flutterSecrets: flutter, secrets: secrets).migrateSettings()
        #expect(outcome.keyToReenter == nil)
        #expect(secrets.apiKey(for: .anthropic) == "sk-ant")
        #expect(secrets.apiKey(for: .openai) == "sk-oai")
        #expect(secrets.apiKey(for: .gemini) == "mine")
        #expect(secrets.apiKey(for: .xai) == "")
    }

    /// The Mac: the data-protection keychain refuses this app, so the key the
    /// reader was using has to be entered again.
    @Test func anUnreadableKeyInUseIsReported() throws {
        let file = try writePlist(["inference_backend": "cloud", "cloud_provider": "gemini"])
        let outcome = mac(preferences: file, flutterSecrets: RefusingSecretStore()).migrateSettings()
        #expect(outcome.keyToReenter == .gemini)
        #expect(mac(preferences: file).completedSteps.contains(.keychain))
    }

    @Test func anUnreadableKeyNotInUseIsNotReported() throws {
        let file = try writePlist(["inference_backend": "platform", "cloud_provider": "gemini"])
        let outcome = mac(preferences: file, flutterSecrets: RefusingSecretStore()).migrateSettings()
        #expect(outcome.keyToReenter == nil)
    }

    @Test func aKeyThisAppAlreadyHasIsNotAskedFor() throws {
        let file = try writePlist(["inference_backend": "cloud", "cloud_provider": "anthropic"])
        let outcome = mac(preferences: file, flutterSecrets: RefusingSecretStore(),
                          secrets: InMemorySecretStore(["anthropic": "sk"])).migrateSettings()
        #expect(outcome.keyToReenter == nil)
    }

    // MARK: - Library

    private func addNote(in directory: URL) async throws {
        let database = try UserDatabase.open(at: directory.appending(path: UserDatabase.fileName))
        try await AnnotationStore(database: database).createNote(
            contentUnitId: nil, charStart: nil, charEnd: nil, quote: nil, body: "Grace",
            sourceTitle: nil, unitTitle: nil, reference: nil)
    }

    private func write(_ text: String, _ name: String, in directory: URL) throws {
        try Data(text.utf8).write(to: directory.appending(path: name))
    }

    private func read(_ name: String, in directory: URL) -> String? {
        (try? Data(contentsOf: directory.appending(path: name))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func copiesTheMacLibraryOverAFreshOne() async throws {
        try await addNote(in: flutterSupport)
        try write("corpus", "theology.db", in: flutterSupport)
        try write("15", "theology.corpus-version", in: flutterSupport)
        try FileManager.default.createDirectory(at: flutterSupport.appending(path: "packs"),
                                                withIntermediateDirectories: true)
        try write("fragment", "packs/a.db.gz", in: flutterSupport)
        // What this app's first launch left: a fresh corpus mid-WAL.
        try write("fresh", "theology.db", in: support)
        try write("wal", "theology.db-wal", in: support)
        try write("shm", "theology.db-shm", in: support)

        let outcome = mac().migrateFiles()
        #expect(outcome.library == nil)
        #expect(ExistingInstall.hasReaderData(in: support))
        #expect(read("theology.db", in: support) == "corpus")
        #expect(read("theology.corpus-version", in: support) == "15")
        #expect(read("packs/a.db.gz", in: support) == "fragment")
        #expect(read("theology.db-wal", in: support) == nil)
        #expect(read("theology.db-shm", in: support) == nil)
        #expect(mac().completedSteps.contains(.files))
        // Flutter's copy stays.
        #expect(read("theology.db", in: flutterSupport) == "corpus")
    }

    @Test func neverCopiesOverThisAppsOwnLibrary() async throws {
        try await addNote(in: flutterSupport)
        try write("flutter", "theology.db", in: flutterSupport)
        try await addNote(in: support)
        try write("native", "theology.db", in: support)
        #expect(mac().migrateFiles().library == nil)
        #expect(read("theology.db", in: support) == "native")
        #expect(mac().completedSteps.contains(.files))
    }

    /// Only the corpus there: nothing of the reader's to bring.
    @Test func skipsAFlutterLibraryWithNothingOfTheReaders() throws {
        try write("flutter", "theology.db", in: flutterSupport)
        try write("native", "theology.db", in: support)
        #expect(mac().migrateFiles().library == nil)
        #expect(read("theology.db", in: support) == "native")
    }

    /// A copy cut short is finished next time, even though what it already
    /// copied now looks like this app's own library.
    @Test func resumesACopyCutShort() async throws {
        try await addNote(in: flutterSupport)
        try write("flutter", "theology.db", in: flutterSupport)
        try await addNote(in: support)
        defaults.set(true, forKey: FlutterMigration.copyInProgressKey)
        #expect(mac().migrateFiles().library == nil)
        #expect(read("theology.db", in: support) == "flutter")
        #expect(defaults.object(forKey: FlutterMigration.copyInProgressKey) == nil)
    }

    @Test func anUnreadableContainerIsReportedAndRetried() async throws {
        try await addNote(in: flutterSupport)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: flutterSupport.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flutterSupport.path) }
        #expect(mac().migrateFiles().library == .unreadable)
        #expect(!mac().completedSteps.contains(.files))
    }

    @Test func noContainerFinishesAtOnce() throws {
        try FileManager.default.removeItem(at: flutterSupport)
        #expect(mac().migrateFiles().library == nil)
        #expect(mac().completedSteps.contains(.files))
    }

    @Test func skippingRecordsTheStep() {
        mac().skip(.files)
        #expect(mac().completedSteps == [.files])
    }

    /// On iPhone the library is already in place: nothing to copy.
    @Test func thePhoneLibraryStaysInPlace() async throws {
        try await addNote(in: support)
        #expect(phone().migrateFiles().library == nil)
        #expect(ExistingInstall.hasReaderData(in: support))
        #expect(phone().completedSteps.contains(.files))
    }

    // MARK: - Models

    @Test func deletesOnlyFlutterGemmasModels() throws {
        try write(String(repeating: "x", count: 1000), "Qwen3_1.7B.litertlm", in: models)
        try write(String(repeating: "x", count: 24), "gemma3-1b-it-q4.task", in: models)
        try write("keep", "notes.txt", in: models)
        try write("keep", "other.litertlm", in: models)
        let outcome = phone().migrateFiles()
        #expect(outcome.removedModelBytes == 1024)
        #expect(read("Qwen3_1.7B.litertlm", in: models) == nil)
        #expect(read("gemma3-1b-it-q4.task", in: models) == nil)
        #expect(read("notes.txt", in: models) == "keep")
        #expect(read("other.litertlm", in: models) == "keep")
        #expect(phone().completedSteps.contains(.models))
        #expect(phone().migrateFiles().removedModelBytes == 0)
    }

    @Test func anUnreadableModelDirectoryIsRetried() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: models.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: models.path) }
        _ = phone().migrateFiles()
        #expect(!phone().completedSteps.contains(.models))
    }
}

/// A keychain this app isn't entitled to, as the Mac's data-protection one is.
private struct RefusingSecretStore: SecretStore {
    func secret(for account: String) throws -> String? { throw KeychainError(status: errSecMissingEntitlement) }
    func setSecret(_ value: String?, for account: String) throws { throw KeychainError(status: errSecMissingEntitlement) }
}

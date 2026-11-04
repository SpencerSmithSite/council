#if os(macOS)
import Foundation
import Testing
@testable import CouncilCore

// The Mac's in-place installer, exercised end to end with throwaway apps and
// disk images built in a temporary folder: hdiutil really mounts them, ditto
// really copies, the swap really renames. Nothing outside the temporary
// folder is touched; the "installed" app is a copy in there, never the app
// running the tests and never /Applications.
//
// No test machine has Council's Developer ID certificate, so the file
// handling runs with `FakeSigning`, and `SecurityCodeSigning` is tested on
// its own against unsigned and ad hoc signed bundles, which it must refuse.
// `signedByTheTeamPasses` runs only when TEST_RUNNER_COUNCIL_SIGNING_IDENTITY
// names a team certificate in the keychain.

/// Answers as the test says instead of checking signatures.
struct FakeSigning: CodeSigning {
    var runningTeam: String? = "TEAMFAKE01"
    var accepts = true

    func validate(app: URL, teamID: String, identifier: String) throws {
        guard accepts else { throw CodeSigningFailure(description: "rejected by the test") }
    }

    func team(of app: URL) -> String? { runningTeam }
}

enum ThrowawayApps {
    static let identifier = "site.spencersmith.council.test"

    /// A minimal app bundle: a real Mach-O (a copy of /usr/bin/true, so
    /// codesign has something to sign), an Info.plist and a marker resource
    /// saying which copy this is.
    @discardableResult
    static func makeApp(in folder: URL, name: String = "Council.app", identifier: String = identifier,
                        version: String, build: String, marker: String) throws -> URL {
        let app = folder.appending(path: name, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Council",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Council",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: contents.appending(path: "MacOS/Council"))
        try Data(marker.utf8).write(to: contents.appending(path: "Resources/marker.txt"))
        return app
    }

    /// A compressed disk image of `folder`, with the usual Applications link.
    static func makeImage(of folder: URL, at image: URL) async throws {
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "Applications"),
                                                   withDestinationURL: URL(filePath: "/Applications"))
        let result = try await ProcessRunner.run("/usr/bin/hdiutil", [
            "create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO", "-volname", "Council",
            "-srcfolder", folder.path, image.path,
        ])
        guard result.status == 0 else { throw ProcessRunner.Failure(description: result.errorText) }
    }

    static func codesign(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run("/usr/bin/codesign", arguments)
        guard result.status == 0 else { throw ProcessRunner.Failure(description: result.errorText) }
    }

    static func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }
}

@Suite(.serialized) struct MacUpdateInstallerTests {
    let root = UpdateFixtures.temporaryDirectory("council-installer-test")

    /// An "installed" old app in its own folder, and a disk image holding a
    /// new one.
    func scenario(newVersion: String = "2026.11.5", newBuild: String = "9",
                  newIdentifier: String = ThrowawayApps.identifier) async throws -> (installed: URL, image: URL) {
        let installedFolder = root.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        let installed = try ThrowawayApps.makeApp(in: installedFolder, version: "2026.10.29", build: "8", marker: "old")

        let source = root.appending(path: "image-source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try ThrowawayApps.makeApp(in: source, identifier: newIdentifier, version: newVersion, build: newBuild, marker: "new")
        let image = root.appending(path: "Council-macos.dmg")
        try await ThrowawayApps.makeImage(of: source, at: image)
        return (installed, image)
    }

    func installer(for installed: URL, signing: FakeSigning = FakeSigning()) -> MacUpdateInstaller {
        MacUpdateInstaller(runningApp: installed, bundleIdentifier: ThrowawayApps.identifier,
                           currentVersion: AppVersion([2026, 10, 29], build: 8), teamID: "TEAMFAKE01",
                           mountRoot: root.appending(path: "mounts", directoryHint: .isDirectory), signing: signing)
    }

    func folderNames(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func noMountsLeft() -> Bool {
        let mounts = root.appending(path: "mounts")
        return folderNames(mounts).isEmpty
    }

    @Test func replacesTheInstalledCopyAndKeepsTheOldOneForTheHelper() async throws {
        let (installed, image) = try await scenario()
        let installer = installer(for: installed)
        #expect(installer.replacementBlocker() == nil)

        let outcome = try await installer.install(diskImage: image)
        guard case .replaced(let app, let previous) = outcome else {
            Issue.record("expected a replacement, got \(outcome)")
            return
        }
        #expect(app == installed.standardizedFileURL)
        #expect(ThrowawayApps.marker(of: installed) == "new")
        #expect(ThrowawayApps.marker(of: previous) == "old")
        #expect(previous.lastPathComponent.hasPrefix(".\(ThrowawayApps.identifier).update-"))
        // Only the app and the old copy awaiting the helper.
        #expect(folderNames(installed.deletingLastPathComponent()).count == 2)
        #expect(noMountsLeft(), "the image is unmounted")

        installer.removeLeftovers()
        #expect(folderNames(installed.deletingLastPathComponent()) == ["Council.app"])
    }

    @Test func aFolderItCannotWriteFallsBackToTheFinder() async throws {
        let (installed, image) = try await scenario()
        let folder = installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let installer = installer(for: installed)
        #expect(installer.replacementBlocker() != nil)
        let outcome = try await installer.install(diskImage: image)
        guard case .manual = outcome else {
            Issue.record("expected the Finder fallback, got \(outcome)")
            return
        }
        #expect(ThrowawayApps.marker(of: installed) == "old")
    }

    @Test func aBuildNotSignedByTheTeamDoesNotReplaceItself() async throws {
        // A development build run with signing off: no team to compare.
        let (installed, image) = try await scenario()
        let installer = installer(for: installed, signing: FakeSigning(runningTeam: nil))
        let outcome = try await installer.install(diskImage: image)
        #expect(outcome == .manual(reason: "This copy of Council isn't signed by its developer."))
        #expect(ThrowawayApps.marker(of: installed) == "old")
    }

    @Test func aDownloadThatFailsItsSignatureIsRefusedOutright() async throws {
        let (installed, image) = try await scenario()
        let installer = installer(for: installed, signing: FakeSigning(accepts: false))
        await #expect(throws: MacUpdateInstaller.Rejection.self) { try await installer.install(diskImage: image) }
        #expect(ThrowawayApps.marker(of: installed) == "old")
        #expect(folderNames(installed.deletingLastPathComponent()) == ["Council.app"], "the staged copy is removed")
        #expect(noMountsLeft())
    }

    @Test func aDownloadThatIsNotNewerIsRefused() async throws {
        let (installed, image) = try await scenario(newVersion: "2026.10.29", newBuild: "8")
        await #expect(throws: MacUpdateInstaller.Rejection.self) {
            try await installer(for: installed).install(diskImage: image)
        }
        #expect(ThrowawayApps.marker(of: installed) == "old")
    }

    @Test func anImageWithoutThisAppFallsBackToTheFinder() async throws {
        let (installed, image) = try await scenario(newIdentifier: "com.example.other")
        let outcome = try await installer(for: installed).install(diskImage: image)
        guard case .manual = outcome else {
            Issue.record("expected the Finder fallback, got \(outcome)")
            return
        }
        #expect(ThrowawayApps.marker(of: installed) == "old")
        #expect(noMountsLeft())
    }

    @Test func aFileThatIsNotADiskImageFallsBackToTheFinder() async throws {
        let (installed, _) = try await scenario()
        let junk = root.appending(path: "junk.dmg")
        try Data("not a disk image".utf8).write(to: junk)
        let outcome = try await installer(for: installed).install(diskImage: junk)
        guard case .manual = outcome else {
            Issue.record("expected the Finder fallback, got \(outcome)")
            return
        }
    }

    @Test func leftoversAreRemovedButNothingElse() throws {
        let folder = root.appending(path: "Apps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try ThrowawayApps.makeApp(in: folder, version: "1", build: "1", marker: "x")
        for name in [".\(ThrowawayApps.identifier).update-incoming-1.app", "Other.app", ".hidden.app"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        installer(for: app).removeLeftovers()
        #expect(folderNames(folder) == [".hidden.app", "Council.app", "Other.app"])
    }

    @Test func theRelaunchHelperWaitsThenRemovesTheOldCopyAndOpensTheNewOne() async throws {
        let previous = root.appending(path: "old.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let opened = root.appending(path: "opened")

        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sleep")
        waiter.arguments = ["1"]
        try waiter.run()

        // touch stands in for open, so the test launches nothing.
        try MacUpdateInstaller.scheduleRelaunch(app: opened, removing: previous, after: waiter.processIdentifier,
                                                opener: "/usr/bin/touch")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: opened.path), "it waits for the process to exit")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: opened.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: opened.path))
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    @Test func theSwapIsAtomicAndBothWaysRound() throws {
        let a = root.appending(path: "a.app", directoryHint: .isDirectory)
        let b = root.appending(path: "b.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: a.appending(path: "id"))
        try Data("B".utf8).write(to: b.appending(path: "id"))
        try MacUpdateInstaller.swap(a, b, asidePrefix: ".test-")
        #expect(try String(contentsOf: a.appending(path: "id"), encoding: .utf8) == "B")
        #expect(try String(contentsOf: b.appending(path: "id"), encoding: .utf8) == "A")
    }
}

@Suite(.serialized) struct SecurityCodeSigningTests {
    let root = UpdateFixtures.temporaryDirectory("council-signing-test")

    @Test func anUnsignedAppIsRefused() async throws {
        let app = try ThrowawayApps.makeApp(in: root, version: "2026.11.5", build: "9", marker: "x")
        try await ThrowawayApps.codesign(["--remove-signature", app.appending(path: "Contents/MacOS/Council").path])
        let signing = SecurityCodeSigning()
        #expect(throws: CodeSigningFailure.self) {
            try signing.validate(app: app, teamID: MacUpdateInstaller.teamID, identifier: ThrowawayApps.identifier)
        }
        #expect(signing.team(of: app) == nil)
    }

    @Test func anAdHocSignedAppIsRefused() async throws {
        // Validly signed, but by nobody: no chain to Apple, so no team.
        let app = try ThrowawayApps.makeApp(in: root, version: "2026.11.5", build: "9", marker: "x")
        try await ThrowawayApps.codesign(["--force", "--sign", "-", "--identifier", ThrowawayApps.identifier, app.path])
        let signing = SecurityCodeSigning()
        #expect(throws: CodeSigningFailure.self) {
            try signing.validate(app: app, teamID: MacUpdateInstaller.teamID, identifier: ThrowawayApps.identifier)
        }
        #expect(signing.team(of: app) == nil)
    }

    @Test func theRequirementPinsAppleAndTheTeam() {
        let requirement = SecurityCodeSigning.requirement(teamID: "Y2Q5JVG8X5", identifier: "site.spencersmith.council")
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "Y2Q5JVG8X5""#))
        #expect(requirement.hasPrefix(#"identifier "site.spencersmith.council""#))
    }

    static let identity = ProcessInfo.processInfo.environment["COUNCIL_SIGNING_IDENTITY"]

    @Test(.enabled(if: identity != nil))
    func signedByTheTeamPasses() async throws {
        let app = try ThrowawayApps.makeApp(in: root, version: "2026.11.5", build: "9", marker: "x")
        try await ThrowawayApps.codesign(["--force", "--sign", Self.identity!, "--identifier",
                                          ThrowawayApps.identifier, app.path])
        let signing = SecurityCodeSigning()
        try signing.validate(app: app, teamID: MacUpdateInstaller.teamID, identifier: ThrowawayApps.identifier)
        #expect(signing.team(of: app) == MacUpdateInstaller.teamID)
        // The same signature is not some other team's, nor some other app.
        #expect(throws: CodeSigningFailure.self) {
            try signing.validate(app: app, teamID: "AAAAAAAAAA", identifier: ThrowawayApps.identifier)
        }
        #expect(throws: CodeSigningFailure.self) {
            try signing.validate(app: app, teamID: MacUpdateInstaller.teamID, identifier: "com.example.other")
        }
        // And a bundle altered after signing fails.
        try Data("tampered".utf8).write(to: app.appending(path: "Contents/Resources/marker.txt"))
        #expect(throws: CodeSigningFailure.self) {
            try signing.validate(app: app, teamID: MacUpdateInstaller.teamID, identifier: ThrowawayApps.identifier)
        }
    }
}
#endif

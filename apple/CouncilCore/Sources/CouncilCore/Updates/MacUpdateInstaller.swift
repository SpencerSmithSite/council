#if os(macOS)
// The Mac's install step. The Flutter app's `_macos` path in
// lib/src/services/updates/update_installer.dart opens the verified disk image
// and leaves the reader to drag the app across; this goes further when it can
// do so safely, and falls back to exactly that when it can't.

import Darwin
import Foundation
import os

/// Replaces the running Council with a downloaded one, then relaunches it.
///
/// Given a disk image whose SHA-256 already matched the manifest
/// (`UpdateService.download`), `install(diskImage:)`:
///
/// 1. mounts it privately and read-only (`DiskImage.attach`);
/// 2. finds the one app in it with this app's bundle identifier;
/// 3. copies that app beside the running one, on the same volume;
/// 4. checks the *copy*, the bytes that will actually be installed: strictly
///    valid, signed by a certificate Apple issued to the same team as the
///    running app (`SecurityCodeSigning`), with the same bundle identifier,
///    and a newer version than this one;
/// 5. unmounts, then swaps the copy and the running bundle in one atomic
///    rename, so there is no moment with no Council in the folder.
///
/// `scheduleRelaunch` then starts a small helper that waits for this process
/// to exit, removes the old copy and opens the new one.
///
/// It replaces the bundle only where the reader can already write: never asks
/// for an administrator password, never elevates. Anything environmental that
/// stands in the way (a folder it can't write, a development build that isn't
/// team-signed, an unexpected disk image) returns `.manual(reason)`, and the
/// app falls back to the Flutter behaviour of opening the image in the Finder.
/// A *verdict* against the download (bad signature, another team, another
/// app, not newer) throws instead, and nothing is installed or opened: the
/// checksum proved these are the published bytes, so a published build that
/// fails its signature is one not to run at all.
public struct MacUpdateInstaller: Sendable {
    /// Council's Apple Developer team, pinned so a copy re-signed by anyone
    /// else never replaces itself with their build or vice versa.
    public static let teamID = "Y2Q5JVG8X5"

    public enum Outcome: Sendable, Equatable {
        /// The new app is at `app`; the old one is at `previous` until the
        /// relaunch helper removes it.
        case replaced(app: URL, previous: URL)
        /// Couldn't be done safely here; `reason` says why, for the reader.
        case manual(reason: String)
    }

    public struct Rejection: Error, Equatable, Sendable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The bundle to replace: `Bundle.main.bundleURL`.
    public let runningApp: URL
    public let bundleIdentifier: String
    public let currentVersion: AppVersion
    public let teamID: String
    /// Where private mounts go; a temporary folder.
    public let mountRoot: URL
    private let signing: any CodeSigning

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Updates")

    public init(
        runningApp: URL = Bundle.main.bundleURL,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "site.spencersmith.council",
        currentVersion: AppVersion = .running(),
        teamID: String = MacUpdateInstaller.teamID,
        mountRoot: URL = FileManager.default.temporaryDirectory.appending(path: "CouncilUpdateMounts", directoryHint: .isDirectory),
        signing: any CodeSigning = SecurityCodeSigning()
    ) {
        self.runningApp = runningApp.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.teamID = teamID
        self.mountRoot = mountRoot
        self.signing = signing
    }

    /// Hidden names beside the running app for the incoming copy and the
    /// outgoing one: prefixed with the bundle id so `removeLeftovers` can
    /// recognise its own and nothing else.
    var leftoverPrefix: String { ".\(bundleIdentifier).update-" }

    // MARK: - Preflight

    /// Why the running app can't replace itself, or nil if it can. Cheap
    /// enough to ask before downloading, so the sheet can say what Install
    /// will do. Reads the disk, so call it off the main actor.
    public func replacementBlocker() -> String? {
        guard runningApp.pathExtension == "app" else {
            return String(localized: "Council isn't running from an app bundle.")
        }
        let parent = runningApp.deletingLastPathComponent()
        // Gatekeeper's App Translocation runs a quarantined app from a
        // read-only copy; the writability test below catches it too, but this
        // says why.
        if runningApp.path.contains("/AppTranslocation/") {
            return String(localized: "Council is running from a temporary location macOS made for it.")
        }
        // Renaming a bundle needs write access to its folder and to the
        // bundle itself (its ".." entry changes). access(2) answers for this
        // user, which is the point: no asking for an administrator.
        guard access(parent.path, W_OK) == 0, access(runningApp.path, W_OK) == 0 else {
            return String(localized: "Council can't write to the folder it's in.")
        }
        guard signing.team(of: runningApp) == teamID else {
            return String(localized: "This copy of Council isn't signed by its developer.")
        }
        return nil
    }

    // MARK: - Install

    /// Installs the app in `diskImage`, which must already have passed its
    /// checksum. See the type's documentation for the steps and what each
    /// failure means.
    public func install(diskImage: URL) async throws(Rejection) -> Outcome {
        if let blocker = replacementBlocker() { return .manual(reason: blocker) }

        let mount: URL
        do {
            mount = try await DiskImage.attach(diskImage, under: mountRoot)
        } catch {
            Self.logger.error("Update image would not mount: \(String(describing: error), privacy: .public)")
            return .manual(reason: String(localized: "The disk image couldn't be opened privately."))
        }

        let parent = runningApp.deletingLastPathComponent()
        let incoming = parent.appending(path: "\(leftoverPrefix)incoming-\(UUID().uuidString).app", directoryHint: .isDirectory)
        let outcome: Result<Void, Rejection>?
        do {
            outcome = try await stage(from: mount, to: incoming)
        } catch {
            outcome = nil
        }
        await DiskImage.detach(mount)
        try? FileManager.default.removeItem(at: mount)

        switch outcome {
        case nil:
            try? FileManager.default.removeItem(at: incoming)
            return .manual(reason: String(localized: "The new version couldn't be copied into place."))
        case .failure(let rejection)?:
            try? FileManager.default.removeItem(at: incoming)
            throw rejection
        case .success?:
            break
        }

        do {
            try Self.swap(incoming, runningApp, asidePrefix: leftoverPrefix)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            Self.logger.error("Swap failed: \(String(describing: error), privacy: .public)")
            return .manual(reason: String(localized: "The new version couldn't be moved into place."))
        }
        // After the swap the old app is at `incoming`.
        return .replaced(app: runningApp, previous: incoming)
    }

    /// Copies the app out of the mounted image to `destination` and checks
    /// the copy. A thrown error is environmental (fall back); a `.failure` is
    /// a verdict against the download.
    private func stage(from mount: URL, to destination: URL) async throws -> Result<Void, Rejection> {
        // An image laid out unexpectedly is left for the reader to look at,
        // as the Flutter app leaves every image.
        guard let source = try findApp(in: mount) else {
            throw ProcessRunner.Failure(description: "no app with this bundle identifier at the top of the image")
        }
        // ditto rather than FileManager: it is what the system uses to copy
        // bundles, and keeps every symlink, extended attribute and the signature
        // exactly.
        let copy = try await ProcessRunner.run("/usr/bin/ditto", [source.path, destination.path], timeout: .seconds(300))
        guard copy.status == 0 else {
            throw ProcessRunner.Failure(description: "ditto failed (\(copy.status)): \(copy.errorText)")
        }
        return check(destination)
    }

    /// The one app at the top of the image with this app's bundle id. Real
    /// directories only: a disk image's "Applications" entry is a symlink to
    /// /Applications, and nothing reached through a link is taken.
    func findApp(in mount: URL) throws -> URL? {
        let entries = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let apps = entries.filter { entry in
            guard entry.pathExtension == "app",
                  let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else { return false }
            return Bundle(url: entry)?.bundleIdentifier == bundleIdentifier
        }
        return apps.count == 1 ? apps[0] : nil
    }

    /// The checks on the staged copy, in order of cheapness.
    func check(_ app: URL) -> Result<Void, Rejection> {
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            return .failure(Rejection(message: String(localized: "The download contains a different app.")))
        }
        let build = (info["CFBundleVersion"] as? String).flatMap(DartInt.tryParse)
        guard let version = AppVersion(parsing: info["CFBundleShortVersionString"] as? String, build: build),
              version > currentVersion else {
            // The manifest's checksum pins the bytes, so this takes control of
            // the manifest; still, never install a downgrade.
            return .failure(Rejection(message: String(localized: "The download isn't newer than this version of Council.")))
        }
        do {
            try signing.validate(app: app, teamID: teamID, identifier: bundleIdentifier)
        } catch {
            Self.logger.error("Update signature rejected: \(String(describing: error), privacy: .public)")
            return .failure(Rejection(message: String(localized: "The download isn't signed by Council's developer, so it wasn't installed.")))
        }
        return .success(())
    }

    /// Exchanges `incoming` and `installed` atomically where the volume can
    /// (`RENAME_SWAP`, APFS); elsewhere moves the old one aside and the new
    /// one in, putting the old one back if the second move fails.
    static func swap(_ incoming: URL, _ installed: URL, asidePrefix: String) throws {
        if renamex_np(incoming.path, installed.path, UInt32(RENAME_SWAP)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let aside = installed.deletingLastPathComponent()
            .appending(path: "\(asidePrefix)aside-\(UUID().uuidString).app", directoryHint: .isDirectory)
        guard rename(installed.path, aside.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(incoming.path, installed.path) == 0 else {
            let failure = errno
            _ = rename(aside.path, installed.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        // Leave the old app where the caller expects it.
        guard rename(aside.path, incoming.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // MARK: - Relaunch

    /// Starts the helper that waits for process `pid` (this one) to exit,
    /// removes `previous` and opens `app`. The caller then quits.
    ///
    /// A shell given the paths as arguments, never spliced into the script,
    /// so no path can be read as a command. It waits at most ten minutes: if
    /// quitting was cancelled and the reader carries on, the new app is
    /// already in place for their next launch, and the old copy (whose files
    /// this process no longer opens by path) is still removed.
    public static func scheduleRelaunch(app: URL, removing previous: URL,
                                        after pid: pid_t = ProcessInfo.processInfo.processIdentifier,
                                        opener: String = "/usr/bin/open") throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "council-relaunch", String(pid), previous.path, app.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let relaunchScript = """
        pid="$1"; previous="$2"; app="$3"; opener="$4"
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2
          waited=$((waited + 1))
          if [ "$waited" -ge 3000 ]; then rm -rf -- "$previous"; exit 0; fi
        done
        rm -rf -- "$previous"
        "$opener" "$app"
        """

    /// Removes what an interrupted update left beside the app: only names
    /// with this app's own hidden prefix. Call at launch, off the main actor.
    public func removeLeftovers() {
        let parent = runningApp.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in entries where name.hasPrefix(leftoverPrefix) && name.hasSuffix(".app") {
            try? FileManager.default.removeItem(at: parent.appending(path: name))
        }
    }
}
#endif

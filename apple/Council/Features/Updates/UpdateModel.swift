import CouncilCore
import Foundation
import Observation
import os
#if os(macOS)
import AppKit
#endif

/// The update check as the screens see it: CouncilCore's `UpdateFlow` (the
/// port of `UpdateProvider`, lib/src/services/updates/update_provider.dart),
/// the "check automatically" setting, and each platform's install step.
///
/// One per process, on `AppModel`, so the sheet raised at launch and the
/// Settings section share one answer (and one download).
///
/// The install step is what differs:
/// - **Mac:** `MacUpdateInstaller` replaces the running app in place and
///   relaunches when it safely can, and otherwise opens the verified disk
///   image in the Finder, which is all the Flutter app's `_macos` path does.
/// - **iPhone and iPad:** nothing installs; the sheet opens TestFlight, as
///   the Flutter app does on iOS.
@Observable @MainActor
final class UpdateModel {
    let flow: UpdateFlow

    /// Settings' "Check for Updates Automatically" (`auto_check_updates`).
    var autoCheck: Bool {
        didSet { preferences.autoCheck = autoCheck }
    }

    /// The launch check found something: the main window raises the sheet.
    var showsLaunchOffer = false

    /// Which window raises the launch sheet, so a Mac with two windows open
    /// at launch shows it once (see `UpdateLaunchOffer`).
    @ObservationIgnored var launchOfferOwner: UUID?

    /// The last Check Now found nothing; Settings says "Council is up to
    /// date." until the next check.
    private(set) var confirmedUpToDate = false

    #if os(macOS)
    /// Why this copy can't replace itself (it isn't team-signed, or its
    /// folder isn't writable), or nil if it can. Asked when an offer appears,
    /// so the sheet says what Install will do before the download.
    private(set) var replacementBlocker: String?
    /// Installing is mounting, copying and checking a signature: seconds,
    /// worth showing.
    private(set) var installing = false
    /// Set when the install fell back to the Finder partway, to say why.
    private(set) var fallbackReason: String?
    /// The new copy is in place and the app is quitting to open it.
    private(set) var relaunching = false
    @ObservationIgnored private let installer = MacUpdateInstaller()
    #endif

    @ObservationIgnored private let preferences: UpdatePreferences
    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Updates")

    init(preferences: UpdatePreferences = UpdatePreferences()) {
        self.preferences = preferences
        autoCheck = preferences.autoCheck
        let staging = ((try? AppModel.supportDirectory()) ?? FileManager.default.temporaryDirectory)
            .appending(path: "updates", directoryHint: .isDirectory)
        flow = UpdateFlow(service: UpdateService(current: .running(), stagingDirectory: staging,
                                                 transport: Self.transport()))
    }

    private static func transport() -> any HTTPTransport {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["COUNCIL_UPDATE_MANIFEST"] {
            return LocalUpdateFiles(manifest: URL(filePath: path))
        }
        #endif
        return UpdateDownloadTransport()
    }

    /// The once-per-launch check (Dart's `_MainScreenState._checkForUpdate`):
    /// silent unless it finds something, then the sheet.
    func checkOnLaunch() async {
        #if os(macOS)
        let installer = self.installer
        await Self.offMain { installer.removeLeftovers() }
        #endif
        await flow.checkOnLaunch(enabled: autoCheck)
        if flow.release != nil {
            await prepareInstall()
            showsLaunchOffer = true
            #if DEBUG && os(macOS)
            await autopilot()
            #endif
        }
    }

    #if DEBUG && os(macOS)
    /// Debug builds only: with `COUNCIL_UPDATE_AUTOPILOT=1` as well as
    /// `COUNCIL_UPDATE_MANIFEST`, accepts the offer the way the sheet's
    /// buttons do (Download, then Install), pausing so each stage can be
    /// looked at. For checking the whole Mac flow on a throwaway copy without
    /// driving the UI.
    private func autopilot() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COUNCIL_UPDATE_AUTOPILOT"] == "1", environment["COUNCIL_UPDATE_MANIFEST"] != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        await flow.download()
        try? await Task.sleep(for: .seconds(4))
        if flow.stage == .ready { await install() }
    }
    #endif

    /// Settings' Check Now. True when there is an update to offer.
    func checkNow() async -> Bool {
        confirmedUpToDate = false
        await flow.check()
        guard flow.release != nil else {
            // Flutter says this whenever the check finds nothing, including
            // when it couldn't reach the site: `UpdateService.check` doesn't
            // tell the two apart, and neither does `UpdateService` here.
            confirmedUpToDate = true
            return false
        }
        await prepareInstall()
        return true
    }

    private func prepareInstall() async {
        #if os(macOS)
        let installer = self.installer
        replacementBlocker = await Self.offMain { installer.replacementBlocker() }
        fallbackReason = nil
        #endif
    }

    /// Whether Install will replace the app in place rather than open the
    /// disk image.
    var replacesInPlace: Bool {
        #if os(macOS)
        replacementBlocker == nil
        #else
        false
        #endif
    }

    /// iPhone and iPad: TestFlight opened (`UpdateProvider.openStore`).
    func storeOpened(_ accepted: Bool) {
        if accepted { flow.handedOff() }
    }

    #if os(macOS)
    /// Installs the verified download (`UpdateProvider.install`).
    func install() async {
        guard let file = flow.downloadedFile, !installing else { return }
        installing = true
        defer { installing = false }
        let installer = self.installer
        let result: Result<MacUpdateInstaller.Outcome, MacUpdateInstaller.Rejection> = await Self.offMain {
            do throws(MacUpdateInstaller.Rejection) {
                return .success(try await installer.install(diskImage: file))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(.replaced(let app, let previous)):
            do {
                try MacUpdateInstaller.scheduleRelaunch(app: app, removing: previous)
            } catch {
                // The new version is installed; it just won't open by itself.
                Self.logger.error("Relaunch helper failed: \(String(describing: error), privacy: .public)")
            }
            relaunching = true
            flow.handedOff()
            Self.quit()
        case .success(.manual(let reason)):
            fallbackReason = reason
            openInFinder(file)
        case .failure(let rejection):
            flow.installFailed(rejection.message)
        }
    }

    /// Quits so the helper can open the new copy.
    ///
    /// The update sheet is closed first, and the request repeated a few
    /// times: checking on macOS 26.2 with a throwaway build, one run's
    /// `terminate` with the sheet still attached was ignored, and the helper
    /// then waited for the reader to quit by hand. Asking again is harmless:
    /// once the app is terminating, a repeat does nothing.
    private static func quit(attempt: Int = 0) {
        for window in NSApplication.shared.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        guard attempt < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            logger.notice("Still running after asking to quit; asking again")
            #if DEBUG
            FileHandle.standardError.write(Data("Council: quit retry \(attempt + 1)\n".utf8))
            #endif
            quit(attempt: attempt + 1)
        }
    }

    /// The Flutter behaviour: the disk image opens with the usual
    /// drag-to-Applications window.
    private func openInFinder(_ file: URL) {
        if NSWorkspace.shared.open(file) {
            flow.handedOff()
        } else {
            flow.installFailed(String(localized: "Could not open the disk image."))
        }
    }
    #endif

    @concurrent
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await work()
    }
}

#if DEBUG
/// Debug builds only, for exercising the whole flow by hand: with
/// `COUNCIL_UPDATE_MANIFEST=/path/updates.json` in the environment, the
/// manifest is read from that file and any other URL from the file of the
/// same name beside it, so a local disk image can stand in for a release.
private struct LocalUpdateFiles: HTTPTransport {
    let manifest: URL

    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        let file = url.lastPathComponent == "updates.json"
            ? manifest
            : manifest.deletingLastPathComponent().appending(path: url.lastPathComponent)
        guard let data = try? Data(contentsOf: file) else {
            return HTTPStreamResponse(statusCode: 404, body: AsyncThrowingStream { $0.finish() })
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                // Slowly enough to watch the bar move.
                let step = max(data.count / 50, 1)
                var offset = 0
                while offset < data.count, !Task.isCancelled {
                    let end = min(offset + step, data.count)
                    continuation.yield(data.subdata(in: offset..<end))
                    offset = end
                    try? await Task.sleep(for: .milliseconds(60))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: 200, body: body)
    }
}
#endif

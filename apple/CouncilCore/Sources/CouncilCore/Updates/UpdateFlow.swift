// Ported from lib/src/services/updates/update_provider.dart; the flow parts
// of test/update_sheet_test.dart are `UpdateFlowTests`.

import Foundation
import Observation

/// Where an update has got to (Dart's `UpdateStage`).
public enum UpdateStage: Sendable, Hashable {
    /// Nothing known yet, or the last check found nothing.
    case idle
    case checking
    /// A newer release exists and is waiting to be accepted.
    case available
    case downloading
    /// Downloaded and verified, waiting to be installed.
    case ready
    /// Handed over: the app is relaunching, the disk image is open in the
    /// Finder, or TestFlight is.
    case handedOff
    case failed
}

/// The app's knowledge of whether it is out of date, and the progress of
/// fixing that.
///
/// One instance for the app, because two places need the same answer and must
/// not each go and ask: the sheet raised at launch, and the Settings row that
/// shows the installed version and checks on demand (the Dart's reason for
/// making `UpdateProvider` shared state).
///
/// Installing is not here: it differs by platform (the Mac replaces itself
/// or opens the disk image; iOS opens TestFlight) and needs the app's own
/// frameworks, so the app does it and reports back with `handedOff()` or
/// `installFailed(_:)`.
@Observable @MainActor
public final class UpdateFlow {
    public private(set) var stage: UpdateStage = .idle
    /// The newer release, when there is one.
    public private(set) var update: AvailableUpdate?
    public private(set) var error: String?
    /// Where a verified download is waiting.
    public private(set) var downloadedFile: URL?
    public private(set) var receivedBytes = 0
    public private(set) var totalBytes = 0

    /// The installed version, for display. Known from the bundle at once,
    /// where the Dart reads it asynchronously from package_info_plus.
    public var currentVersion: AppVersion { service.currentVersion }

    public var release: PlatformRelease? { update?.release }

    /// True while a check or a download is in flight.
    public var busy: Bool { stage == .checking || stage == .downloading }

    /// Download progress from 0 to 1, or nil when the total size isn't known.
    /// An indeterminate bar is the honest thing to show then: the model
    /// download once drew a full bar throughout (the Dart's warning).
    public var progress: Double? {
        guard stage == .downloading, totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    /// True when this platform is sent to a store rather than installing.
    public var goesToStore: Bool { release?.delivery == .store }

    @ObservationIgnored private let service: UpdateService
    /// So the launch check runs once per launch, not again whenever the view
    /// that triggers it reappears.
    @ObservationIgnored private var checkedThisLaunch = false
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    public init(service: UpdateService) {
        self.service = service
    }

    /// The once-per-launch check.
    ///
    /// Silent about everything except finding something: no spinner, no
    /// error, nothing on a device with no network. It wasn't asked for, so it
    /// mustn't interrupt.
    public func checkOnLaunch(enabled: Bool) async {
        guard !checkedThisLaunch, enabled else { return }
        checkedThisLaunch = true
        await check(quiet: true)
    }

    /// `quiet` suppresses the checking state, for the launch check. A reader
    /// who pressed Check Now sees it.
    public func check(quiet: Bool = false) async {
        guard !busy else { return }
        if !quiet {
            stage = .checking
            error = nil
        }
        let found = await service.check()
        update = found
        stage = found == nil ? .idle : .available
    }

    /// Fetches the update and verifies it. Not the route on a store platform,
    /// which opens the store instead.
    public func download() async {
        guard let release, !busy else { return }
        stage = .downloading
        error = nil
        receivedBytes = 0
        totalBytes = release.bytes ?? 0

        let service = self.service
        // Holds the flow until the download ends; the flow lives as long as
        // the app anyway.
        let task = Task {
            let result: Result<URL, UpdateError>
            do throws(UpdateError) {
                result = .success(try await service.download(release) { got, total in
                    Task { @MainActor in self.reportProgress(got, total) }
                })
            } catch {
                result = .failure(error)
            }
            self.finishDownload(result)
        }
        downloadTask = task
        await task.value
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    private func reportProgress(_ received: Int, _ total: Int) {
        // Hops can land out of order, or after the download has finished.
        guard stage == .downloading, received > receivedBytes else { return }
        receivedBytes = received
        if total > 0 { totalBytes = total }
    }

    private func finishDownload(_ result: Result<URL, UpdateError>) {
        downloadTask = nil
        switch result {
        case .success(let file):
            downloadedFile = file
            receivedBytes = totalBytes
            stage = .ready
        case .failure(.cancelled):
            // Their own doing: back to the offer, with nothing said about it.
            stage = .available
            receivedBytes = 0
        case .failure(let failure):
            error = failure.message
            stage = .failed
        }
    }

    /// The installer, the disk image or the store page has taken over.
    public func handedOff() {
        stage = .handedOff
    }

    /// Installing failed; `message` says how. The sheet offers to try again.
    public func installFailed(_ message: String) {
        error = message
        stage = .failed
    }

    /// Puts the offer away for this launch. It comes back next time, since
    /// the app is still out of date, but nagging twice in one sitting is not
    /// how to make that point.
    public func dismiss() {
        guard stage == .available || stage == .failed else { return }
        stage = .idle
        update = nil
        error = nil
    }

    /// "57 MB", or "1.2 GB" from 1024 MB up: the sheet's size line (Dart's
    /// `UpdateSheet._size`).
    public nonisolated static func sizeText(megabytes: Int) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", Double(megabytes) / 1024) : "\(megabytes) MB"
    }
}

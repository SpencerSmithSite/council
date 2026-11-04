import Foundation
import Testing
@testable import CouncilCore

// Ports of test/app_version_test.dart, test/release_manifest_test.dart,
// test/update_service_test.dart and the flow half of
// test/update_sheet_test.dart. The golden fixture (UpdatesGoldenTests) covers
// parsing exhaustively; these keep the Dart tests' reasons beside each check.

private func v(_ text: String) -> AppVersion { AppVersion(parsing: text)! }

@Suite struct AppVersionTests {
    @Test func readsTheDatePartsAndTheBuildCounter() {
        let parsed = v("2026.8.2+7")
        #expect(parsed.parts == [2026, 8, 2])
        #expect(parsed.build == 7)
        #expect(parsed.name == "2026.8.2")
        #expect(parsed.description == "2026.8.2+7")
    }

    @Test func acceptsAReleaseTag() {
        #expect(v("v2026.8.2") == v("2026.8.2"))
    }

    @Test func anExplicitBuildWinsOverOneSplicedIntoTheName() {
        #expect(AppVersion(parsing: "2026.8.2+7", build: 9)?.build == 9)
    }

    @Test func returnsNilRatherThanThrowingOnAnythingUnreadable() {
        for bad in ["", "   ", "nightly", "2026.x.2", "-1.0", "v"] {
            #expect(AppVersion(parsing: bad) == nil, "\(bad)")
        }
        #expect(AppVersion(parsing: nil) == nil)
    }

    @Test func theTenthOfAMonthIsNewerThanTheSecond() {
        // The trap being avoided: as strings, the tenth sorts before the second.
        #expect("2026.8.2" > "2026.8.10")
        #expect(v("2026.8.10") > v("2026.8.2"))
    }

    @Test func octoberIsNewerThanSeptember() {
        #expect("2026.9.1" > "2026.10.1")
        #expect(v("2026.10.1") > v("2026.9.1"))
    }

    @Test func aNewYearIsNewer() {
        #expect(v("2027.1.5") > v("2026.12.31"))
    }

    @Test func aRebuildOfTheSameDayIsAnUpdate() {
        #expect(v("2026.8.2+8") > v("2026.8.2+7"))
    }

    @Test func theDateOutranksTheBuildCounter() {
        #expect(v("2026.8.3+1") > v("2026.8.2+99"))
    }

    @Test func missingPartsCountAsZero() {
        #expect(v("2026.8") == v("2026.8.0"))
        #expect(v("2026.8").hashValue == v("2026.8.0").hashValue)
        #expect(v("2026.8.1") > v("2026.8"))
    }

    @Test func theSameVersionIsNotAnUpdate() {
        #expect(!(v("2026.8.2+7") > v("2026.8.2+7")))
    }

    @Test func theRunningBuildComesFromTheBundle() {
        // The test runner's bundle has no Council version: impossibly new, so
        // a broken bundle is never offered an update forever.
        let unreadable = AppVersion.running(in: Bundle(for: BundleToken.self))
        #expect(unreadable == .impossiblyNew || unreadable.parts.first ?? 0 > 0)
    }
}

private final class BundleToken {}

@Suite struct ReleaseManifestTests {
    static let sha = "03e2015837e4fd29de353dc3db079af3bbdc1bccaf0c76a23b5c6697bbb5d485"

    func manifest(macos: [String: Any]? = nil, extra: [String: Any] = [:]) -> Data {
        var platforms: [String: Any] = [
            "macos": macos ?? [
                "kind": "download",
                "url": "https://github.com/SpencerSmithSite/council/releases/download/v2026.8.2/Council-macos.dmg",
                "bytes": 59_382_899,
                "sha256": Self.sha,
            ],
        ]
        platforms.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: [
            "schema": 1, "version": "2026.8.2", "build": 7, "notes": "What changed.",
            "url": "https://www.spencersmith.site/council/download.html", "platforms": platforms,
        ] as [String: Any])
    }

    @Test func readsARelease() throws {
        let m = try ReleaseManifest.parse(manifest())
        #expect(m.version.name == "2026.8.2")
        #expect(m.version.build == 7)
        #expect(m.notes == "What changed.")
        let mac = try #require(m.platforms["macos"])
        #expect(mac.delivery == .download)
        #expect(mac.bytes == 59_382_899)
        #expect(mac.megabytes == 56)
        #expect(mac.sha256 == Self.sha)
        // The system decides what to do with a download by its extension.
        #expect(mac.fileName == "Council-macos.dmg")
    }

    @Test func aStorePlatformNeedsNoSizeOrChecksum() throws {
        let m = try ReleaseManifest.parse(manifest(extra: [
            "ios": ["kind": "store", "url": "https://testflight.apple.com/join/JZ1k29YE"],
        ]))
        #expect(m.platforms["ios"]?.delivery == .store)
        #expect(m.platforms["ios"]?.sha256 == nil)
    }

    @Test func aPlatformInheritsTheReleaseVersionOrOverridesIt() throws {
        let m = try ReleaseManifest.parse(manifest(extra: [
            "ios": ["kind": "store", "url": "https://testflight.apple.com/join/JZ1k29YE", "version": "2026.7.27"],
        ]))
        #expect(m.platforms["macos"]?.version.name == "2026.8.2")
        // A store can lag behind the direct downloads.
        #expect(m.platforms["ios"]?.version.name == "2026.7.27")
    }

    nonisolated(unsafe) static let rejected: [(String, [String: Any])] = [
        ("no checksum", ["kind": "download", "url": "https://example.com/v2026.8.2/Council.dmg", "bytes": 100]),
        ("a checksum that is not a sha256",
         ["kind": "download", "url": "https://example.com/v2026.8.2/Council.dmg", "bytes": 100, "sha256": "deadbeef"]),
        ("no size", ["kind": "download", "url": "https://example.com/v2026.8.2/Council.dmg", "sha256": sha]),
        ("plain http", ["kind": "download", "url": "http://example.com/v2026.8.2/Council.dmg", "bytes": 100, "sha256": sha]),
        ("an unknown delivery kind",
         ["kind": "torrent", "url": "https://example.com/v2026.8.2/Council.dmg", "bytes": 100, "sha256": sha]),
    ]

    @Test(arguments: rejected.map(\.0))
    func refusesAnythingItCannotVerify(_ why: String) {
        let entry = Self.rejected.first { $0.0 == why }!.1
        // The only platform was unusable, so there is no manifest.
        #expect(throws: ReleaseManifestError.self) { try ReleaseManifest.parse(manifest(macos: entry)) }
    }

    @Test func anUnusablePlatformDoesNotTakeTheOthersDownWithIt() throws {
        let m = try ReleaseManifest.parse(manifest(macos: Self.rejected[0].1, extra: [
            "android": ["kind": "download", "url": "https://example.com/Council-android.apk",
                        "bytes": 59_382_899, "sha256": Self.sha],
        ]))
        #expect(m.platforms["macos"] == nil)
        #expect(m.platforms["android"] != nil)
    }

    @Test func aManifestWithNoVersionIsNotAManifest() {
        let json = #"{"platforms":{"ios":{"kind":"store","url":"https://testflight.apple.com/join/x"}}}"#
        #expect(throws: ReleaseManifestError.self) { try ReleaseManifest.parse(Data(json.utf8)) }
    }

    @Test func theChecksumIsMatchedCaseInsensitivelyButStoredLowerCase() throws {
        let m = try ReleaseManifest.parse(manifest(macos: [
            "kind": "download", "url": "https://example.com/Council.dmg", "bytes": 100, "sha256": Self.sha.uppercased(),
        ]))
        #expect(m.platforms["macos"]?.sha256 == Self.sha)
    }

    @Test func theFileNameIsASingleHarmlessPathComponent() {
        func name(_ url: String) -> String {
            PlatformRelease(platform: "macos", delivery: .download, url: URL(string: url)!,
                            version: AppVersion([2026, 8, 2], build: 7)).fileName
        }
        #expect(name("https://h/d/Council-2026.8.2.dmg") == "Council-2026.8.2.dmg")
        // A percent-encoded traversal can't escape the staging directory.
        let traversal = name("https://h/council/%2e%2e%2f%2e%2e%2fLibrary%2fLaunchAgents%2fx.plist")
        #expect(!traversal.contains("/") && !traversal.contains(".."))
        #expect(traversal == "x.plist")
        #expect(!name("https://h/d/%2e%2e%5c%2e%2e%5cstartup%5cx.exe").contains("\\"))
        #expect(name("https://h/d/%2e%2e") == "Council-update")
        #expect(name("https://h/d/.hidden.dmg") == "hidden.dmg")
        #expect(name("https://h") == "Council-update")
        #expect(name("https://h/d/") == "Council-update")
    }

    @Test func sizeText() {
        #expect(UpdateFlow.sizeText(megabytes: 56) == "56 MB")
        #expect(UpdateFlow.sizeText(megabytes: 1023) == "1023 MB")
        #expect(UpdateFlow.sizeText(megabytes: 1536) == "1.5 GB")
    }
}

@Suite struct UpdatePreferencesTests {
    @Test func checkingAutomaticallyIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "council-update-prefs-\(UUID().uuidString)")!
        let prefs = UpdatePreferences(defaults: defaults)
        #expect(prefs.autoCheck)
        prefs.autoCheck = false
        #expect(!prefs.autoCheck)
        #expect(defaults.object(forKey: "auto_check_updates") as? Bool == false)
    }
}

@Suite struct UpdateServiceTests {
    let staging = UpdateFixtures.temporaryDirectory().appending(path: "updates", directoryHint: .isDirectory)

    func service(_ server: FakeUpdateServer, current: AppVersion = AppVersion([2026, 8, 1], build: 6),
                 platform: String = "macos", free: Int64? = 100_000_000_000,
                 checkTimeout: Duration = .seconds(12), chunkTimeout: Duration = .seconds(120)) -> UpdateService {
        UpdateService(current: current, stagingDirectory: staging, transport: server, platform: platform,
                      freeBytes: { _ in free }, checkTimeout: checkTimeout, chunkTimeout: chunkTimeout)
    }

    func server(manifest: String = UpdateFixtures.manifest(), installer: Data = UpdateFixtures.installer,
                configure: (inout FakeUpdateServer.Config) -> Void = { _ in }) -> FakeUpdateServer {
        var config = FakeUpdateServer.Config(manifest: manifest, installer: installer)
        configure(&config)
        return FakeUpdateServer(config)
    }

    func stagedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }

    // MARK: Checking

    @Test func offersANewerRelease() async {
        let found = await service(server(manifest: UpdateFixtures.manifest(notes: "Better search."))).check()
        #expect(found?.release.version.name == "2026.8.2")
        #expect(found?.notes == "Better search.")
        #expect(found?.page?.absoluteString == "https://www.spencersmith.site/council/download.html")
    }

    @Test func saysNothingWhenThisBuildIsCurrent() async {
        #expect(await service(server(), current: AppVersion([2026, 8, 2], build: 7)).check() == nil)
    }

    @Test func saysNothingWhenThePublishedBuildIsOlder() async {
        #expect(await service(server(manifest: UpdateFixtures.manifest(version: "2026.7.27"))).check() == nil)
    }

    @Test func aRebuildOfTheSameDayIsAnUpdate() async {
        let found = await service(server(manifest: UpdateFixtures.manifest(build: 8)),
                                  current: AppVersion([2026, 8, 2], build: 7)).check()
        #expect(found != nil)
    }

    @Test func iOSReadsItsOwnStoreEntry() async {
        let found = await service(server(), platform: "ios").check()
        // The Dart fixture's iOS entry inherits 2026.8.2+7.
        #expect(found?.release.delivery == .store)
    }

    @Test func aFailedFetchIsSilentNotAnError() async {
        // This runs unprompted at launch: a reader with no network asked for
        // nothing and should be told nothing.
        #expect(await service(server(manifest: "") { $0.manifestStatus = 500 }).check() == nil)
        #expect(await service(server(manifest: "not json at all")).check() == nil)
        #expect(await service(server(manifest: #"{"version":"nightly"}"#)).check() == nil)
    }

    @Test func aCheckThatHangsIsAbandoned() async {
        let hanging = server { $0.hangBeforeHeaders = true }
        #expect(await service(hanging, checkTimeout: .milliseconds(100)).check() == nil)
    }

    @Test func theManifestIsNeverAnsweredFromACache() async {
        final class Recorder: HTTPTransport, @unchecked Sendable {
            var policy: URLRequest.CachePolicy?
            func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
                policy = request.cachePolicy
                return HTTPStreamResponse(statusCode: 404, body: AsyncThrowingStream { $0.finish() })
            }
        }
        let recorder = Recorder()
        _ = await UpdateService(current: AppVersion([1]), stagingDirectory: staging, transport: recorder).fetchManifest()
        #expect(recorder.policy == .reloadIgnoringLocalCacheData)
    }

    // MARK: Downloading

    @Test func writesTheFileReportsProgressAndKeepsIt() async throws {
        let service = service(server())
        let release = try #require(await service.check()).release
        let seen = Seen()
        let file = try await service.download(release) { received, total in
            seen.add(received, total)
        }
        let data = try Data(contentsOf: file)
        #expect(data == UpdateFixtures.installer)
        let (received, totals) = seen.values
        #expect(totals.allSatisfy { $0 == UpdateFixtures.installer.count })
        // Progress that starts at the end is not progress.
        #expect(try #require(received.first) < UpdateFixtures.installer.count)
        #expect(received.last == UpdateFixtures.installer.count)
        #expect(received == received.sorted())
    }

    @Test func discardsADownloadWhoseBytesAreNotThePublishedOnes() async throws {
        // The load-bearing test: what this returns is installed and run with
        // the reader's own privileges.
        var tampered = UpdateFixtures.installer
        tampered[10] ^= 0xFF
        let service = service(server(installer: tampered))
        let release = try #require(await service.check()).release
        await #expect(throws: UpdateError.checksumMismatch) { try await service.download(release) }
        #expect(UpdateError.checksumMismatch.message.contains("did not match its checksum"))
        // A rejected installer must not be left lying about.
        #expect(stagedFiles().isEmpty)
    }

    @Test func refusesToStartWithoutRoomOnDisk() async throws {
        let service = service(server(), free: 1_048_576)
        let release = try #require(await service.check()).release
        await #expect(throws: UpdateError.notEnoughSpace(megabytes: 0)) { try await service.download(release) }
        #expect(UpdateError.notEnoughSpace(megabytes: 0).message.contains("free space"))
    }

    @Test func aCancelledDownloadLeavesNothingBehind() async throws {
        let service = service(server())
        let release = try #require(await service.check()).release
        // Cancelled part-way, the way a reader does it.
        let box = CancelBox()
        let task = Task { () async throws -> URL in
            try await service.download(release) { received, _ in
                if received >= 8 * 1024 { box.cancel() }
            }
        }
        box.set { task.cancel() }
        await #expect(throws: UpdateError.cancelled) { try await task.value }
        // Half an installer is worse than none.
        #expect(stagedFiles().isEmpty)
    }

    @Test func aCancelFromAnAbandonedAttemptDoesNotKillTheNextOne() async throws {
        let service = service(server())
        let release = try #require(await service.check()).release
        let abandoned = Task { try await service.download(release) }
        abandoned.cancel()
        _ = await abandoned.result
        let file = try await service.download(release)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func stagingIsClearedBeforeEachAttempt() async throws {
        let service = service(server())
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Abandoned installer, left by an update that went wrong.
        try Data([1, 2, 3]).write(to: staging.appending(path: "Council-old.dmg"))
        let release = try #require(await service.check()).release
        _ = try await service.download(release)
        #expect(stagedFiles() == [release.fileName])
    }

    @Test func aDownloadThatNeverStartsTimesOut() async throws {
        let release = try #require(await service(server()).check()).release
        let hanging = service(server { $0.hangBeforeHeaders = true }, checkTimeout: .milliseconds(100))
        await #expect(throws: UpdateError.startTimedOut) { try await hanging.download(release) }
        #expect(stagedFiles().isEmpty)
    }

    @Test func aDownloadThatStallsIsStopped() async throws {
        let release = try #require(await service(server()).check()).release
        var half = UpdateFixtures.installer
        half.removeLast(half.count / 2)
        let stalling = service(server(installer: half) { $0.hangAfterChunks = true }, chunkTimeout: .milliseconds(200))
        await #expect(throws: UpdateError.stalled) { try await stalling.download(release) }
        #expect(stagedFiles().isEmpty)
    }

    @Test func anHTTPErrorSaysSo() async throws {
        let release = try #require(await service(server()).check()).release
        let missing = service(server { $0.installerStatus = 404 })
        await #expect(throws: UpdateError.httpStatus(404)) { try await missing.download(release) }
        #expect(UpdateError.httpStatus(404).message == "Download failed (HTTP 404).")
    }

    @Test func aStoreReleaseIsNotDownloaded() async throws {
        let release = try #require(await service(server(), platform: "ios").check()).release
        await #expect(throws: UpdateError.notADownload) { try await service(server()).download(release) }
    }
}

/// Cancels a task from inside its own progress callback, whichever of the
/// two arrives first.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false

    func set(_ action: @escaping @Sendable () -> Void) {
        let now = lock.withLock { self.action = action; return requested }
        if now { action() }
    }

    func cancel() {
        let action = lock.withLock { requested = true; return self.action }
        action?()
    }
}

/// Progress reports, collected from whatever thread they arrive on.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int] = []
    private var totals: [Int] = []

    func add(_ got: Int, _ total: Int) {
        lock.withLock {
            received.append(got)
            totals.append(total)
        }
    }

    var values: ([Int], [Int]) { lock.withLock { (received, totals) } }
}

@MainActor @Suite struct UpdateFlowTests {
    let installer = Data((0..<(40 * 1024)).map { UInt8($0 % 251) })

    func flow(kind: String = "download", body: AsyncThrowingStream<Data, any Error>? = nil,
              installerBytes: Data? = nil) -> (UpdateFlow, FakeUpdateServer) {
        let manifest: String
        if kind == "store" {
            manifest = #"{"version":"2026.8.9","build":12,"platforms":{"macos":{"kind":"store","url":"https://testflight.apple.com/join/JZ1k29YE"}}}"#
        } else {
            manifest = UpdateFixtures.manifest(version: "2026.8.9", build: 12, installer: installer)
        }
        let server = FakeUpdateServer(.init(manifest: manifest, installer: installerBytes ?? installer,
                                            installerStream: body))
        let service = UpdateService(current: AppVersion([2026, 8, 2], build: 7),
                                    stagingDirectory: UpdateFixtures.temporaryDirectory(), transport: server,
                                    platform: "macos", freeBytes: { _ in 100_000_000_000 })
        return (UpdateFlow(service: service), server)
    }

    /// Waits for the main actor to catch up with the progress hops.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func offersTheNewVersionWithWhatItWillCost() async throws {
        let (flow, _) = flow()
        await flow.check()
        #expect(flow.stage == .available)
        #expect(flow.release?.version.name == "2026.8.9")
        #expect(flow.currentVersion.name == "2026.8.2")
        #expect(flow.release?.bytes == installer.count)
        #expect(!flow.goesToStore)
    }

    @Test func nothingDownloadsUntilItIsAskedTo() async {
        let (flow, server) = flow()
        await flow.check()
        // The check is automatic; the download is a decision.
        #expect(flow.stage == .available)
        #expect(server.installerRequests == 0)
        #expect(flow.progress == nil)
    }

    @Test func theBarShowsHowFarAlongItActuallyIs() async throws {
        let (stream, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (flow, _) = flow(body: stream)
        await flow.check()
        let downloading = Task { await flow.download() }
        feed.yield(installer.prefix(10 * 1024))
        await eventually { flow.receivedBytes >= 10 * 1024 }
        // A quarter of the way in.
        #expect(abs((flow.progress ?? 0) - 0.25) < 0.01)
        #expect(flow.stage == .downloading)
        #expect(flow.busy)

        feed.yield(installer.suffix(from: 10 * 1024))
        feed.finish()
        await downloading.value
        #expect(flow.stage == .ready)
        #expect(flow.downloadedFile != nil)
    }

    @Test func aDownloadThatFailsItsChecksumSaysSoAndOffersARetry() async {
        var tampered = installer
        tampered[3] ^= 0xFF
        let (flow, _) = flow(installerBytes: tampered)
        await flow.check()
        await flow.download()
        #expect(flow.stage == .failed)
        #expect(flow.error?.contains("did not match its checksum") == true)
        // An installer that can't be verified is never offered.
        #expect(flow.downloadedFile == nil)
    }

    @Test func aStorePlatformIsSentToTheStoreInstead() async {
        let (flow, _) = flow(kind: "store")
        await flow.check()
        #expect(flow.goesToStore)
    }

    @Test func cancellingGoesBackToTheOfferSayingNothing() async {
        let (stream, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (flow, _) = flow(body: stream)
        await flow.check()
        let downloading = Task { await flow.download() }
        feed.yield(installer.prefix(4 * 1024))
        await eventually { flow.receivedBytes > 0 }
        flow.cancelDownload()
        await downloading.value
        #expect(flow.stage == .available)
        #expect(flow.error == nil)
        #expect(flow.receivedBytes == 0)
    }

    @Test func theLaunchCheckRunsOncePerLaunchAndOnlyWhenEnabled() async {
        let (flow, server) = flow()
        await flow.checkOnLaunch(enabled: false)
        #expect(server.requests.isEmpty)
        await flow.checkOnLaunch(enabled: true)
        await flow.checkOnLaunch(enabled: true)
        #expect(server.requests.count == 1)
        #expect(flow.stage == .available)
    }

    @Test func dismissingPutsTheOfferAwayForThisLaunch() async {
        let (flow, _) = flow()
        await flow.check()
        flow.dismiss()
        #expect(flow.stage == .idle)
        #expect(flow.release == nil)
    }

    @Test func installingReportsBack() async {
        let (flow, _) = flow()
        await flow.check()
        await flow.download()
        flow.installFailed("Could not open the disk image.")
        #expect(flow.stage == .failed)
        #expect(flow.error == "Could not open the disk image.")
        flow.handedOff()
        #expect(flow.stage == .handedOff)
    }
}

/// The real updates.json, opt-in (COUNCIL_LIVE_UPDATES=1) because it needs the
/// network: it must parse, and this build's own version must not be offered
/// itself.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COUNCIL_LIVE_UPDATES"] == "1"))
struct LiveUpdateManifestTests {
    @Test func theLiveManifestParsesAndThisBuildIsCurrent() async throws {
        let staging = UpdateFixtures.temporaryDirectory()
        let current = AppVersion([2026, 10, 29], build: 8)
        for platform in ["macos", "ios"] {
            let service = UpdateService(current: current, stagingDirectory: staging, platform: platform)
            let manifest = try #require(await service.fetchManifest())
            let release = try #require(manifest.platforms[platform])
            print("live \(platform): \(release.version) \(release.delivery) \(release.bytes.map(String.init) ?? "-") bytes")
            #expect(await service.check() == nil, "2026.10.29+8 is offered nothing on \(platform)")
        }
    }
}

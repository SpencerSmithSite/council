import Foundation
import Testing
@testable import CouncilCore

/// Download, verification, layout, resume, cancel and delete, against an
/// in-memory transport.
///
/// The property that matters most is the one the Dart could only hope for: a
/// download that is interrupted, cancelled, truncated or corrupted never
/// leaves a model that `isDownloaded` accepts.
@Suite struct LocalModelStoreTests {
    let root: URL
    let fake = FakeModel()

    init() throws {
        root = try temporaryDirectory().appending(path: "MLXModels", directoryHint: .isDirectory)
    }

    func store(_ behaviour: FakeModelTransport.Behaviour = .normal,
               freeBytes: Int64? = 100_000_000_000) -> (LocalModelStore, FakeModelTransport) {
        let transport = FakeModelTransport(files: fake.files, behaviour: behaviour)
        return (LocalModelStore(root: root, transport: transport, freeBytes: { _ in freeBytes }), transport)
    }

    /// Runs a download to the end, returning every progress value seen.
    @discardableResult
    func drain(_ stream: AsyncThrowingStream<LocalModelDownloadProgress, any Error>) async throws
        -> [LocalModelDownloadProgress] {
        var seen: [LocalModelDownloadProgress] = []
        for try await progress in stream { seen.append(progress) }
        return seen
    }

    // MARK: - Layout

    @Test func installsIntoItsOwnDirectoryWithAMarkerAndNoStagingLeft() async throws {
        let (store, _) = store()
        #expect(!store.isDownloaded(fake.model))
        try await drain(store.download(fake.model))

        let directory = root.appending(path: "fake-model")
        #expect(store.directory(for: fake.model).path == directory.path)
        for (path, data) in fake.files {
            #expect(try Data(contentsOf: directory.appending(path: path)) == data, "\(path)")
        }
        let marker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "council-model.json"))) as? [String: String]
        #expect(marker == ["id": "fake-model", "repository": "test/fake-model",
                           "revision": String(repeating: "a", count: 40)])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".downloads").path))
        #expect(store.isDownloaded(fake.model))
        #expect(store.bytesOnDisk(for: fake.model) >= fake.totalBytes)
        #expect(!store.isDownloading(fake.model))
    }

    @Test func theRootIsExcludedFromBackup() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func theDefaultRootIsInApplicationSupport() throws {
        let url = try LocalModelStore.defaultRoot()
        #expect(url.lastPathComponent == "MLXModels")
        #expect(url.path.contains("Application Support"))
        #if os(macOS)
        // Under the bundle id on the Mac, as the corpus is (AppModel.supportDirectory).
        let app = try LocalModelStore.defaultRoot(bundleIdentifier: "site.spencersmith.council")
        #expect(app.deletingLastPathComponent().lastPathComponent == "site.spencersmith.council")
        #expect(try LocalModelStore.defaultRoot(bundleIdentifier: nil) == app)
        #endif
    }

    @Test func progressRisesToCompletionAndEndsFinished() async throws {
        let (store, _) = store()
        let seen = try await drain(store.download(fake.model))
        #expect(seen.first?.phase == .preparing || seen.first?.phase == .downloading)
        #expect(seen.last == LocalModelDownloadProgress(modelID: "fake-model", completedBytes: fake.totalBytes,
                                                        totalBytes: fake.totalBytes, phase: .finished))
        #expect(seen.last?.fraction == 1)
        #expect(seen.last?.percent == 100)
        let completed = seen.map(\.completedBytes)
        #expect(completed == completed.sorted())
    }

    @Test func downloadingWhatIsAlreadyThereFetchesNothing() async throws {
        let (store, transport) = store()
        try await drain(store.download(fake.model))
        let before = transport.requests.count
        let seen = try await drain(store.download(fake.model))
        #expect(transport.requests.count == before)
        #expect(seen.map(\.phase) == [.finished])
    }

    // MARK: - What counts as downloaded

    @Test func aModelWithoutItsMarkerIsNotDownloaded() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        try FileManager.default.removeItem(at: store.directory(for: fake.model).appending(path: "council-model.json"))
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func aModelWithAFileTheWrongSizeIsNotDownloaded() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        try Data("x".utf8).write(to: store.directory(for: fake.model).appending(path: "model.safetensors"))
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func anOlderRevisionIsNotDownloadedAndIsReplaced() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        // The same id, re-pinned to another commit in a later app version.
        let repinned = LocalModel(id: fake.model.id, name: fake.model.name, repository: fake.model.repository,
                                  revision: String(repeating: "b", count: 40), files: fake.model.files,
                                  ramMB: 100, minDeviceRAMMB: 1000, minPhoneRAMMB: 1000, maxTokens: 512,
                                  contextBudgetChars: 1000, thinksByDefault: true, note: "")
        #expect(!store.isDownloaded(repinned))
        try await drain(store.download(repinned))
        #expect(store.isDownloaded(repinned))
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func downloadedModelsListsOnlyCatalogueModelsThatAreComplete() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        #expect(store.downloadedModels().isEmpty, "the fake model isn't in the catalogue")
    }

    // MARK: - Delete

    @Test func deleteRemovesACompleteModel() async throws {
        let (store, _) = store()
        try await drain(store.download(fake.model))
        try await store.delete(fake.model)
        #expect(!store.isDownloaded(fake.model))
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: fake.model).path))
        #expect(store.bytesOnDisk(for: fake.model) == 0)
    }

    @Test func deleteRemovesAPartialDownloadToo() async throws {
        let (store, _) = store(.dropsOnceAfter(10_000))
        await #expect(throws: LocalModelStoreError.self) { try await drain(store.download(fake.model)) }
        #expect(store.resumableBytes(for: fake.model) > 0)
        try await store.delete(fake.model)
        #expect(store.resumableBytes(for: fake.model) == 0)
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory(for: fake.model).path))
    }

    @Test func deleteStopsADownloadInProgress() async throws {
        let (store, transport) = store(.stallsAfter(10_000))
        let consumer = Task { try await drain(store.download(fake.model)) }
        var stalls = transport.stalls.makeAsyncIterator()
        _ = await stalls.next()
        #expect(store.isDownloading(fake.model))
        try await store.delete(fake.model)
        #expect(!store.isDownloading(fake.model))
        #expect(store.bytesOnDisk(for: fake.model) == 0)
        _ = try? await consumer.value
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func deletingWhatIsNotThereIsFine() async throws {
        let (store, _) = store()
        try await store.delete(fake.model)
    }

    // MARK: - Cancel and resume

    @Test func cancellingKeepsThePartialAndNeverLooksComplete() async throws {
        let (store, transport) = store(.stallsAfter(20_000))
        let consumer = Task { try await drain(store.download(fake.model)) }
        var stalls = transport.stalls.makeAsyncIterator()
        _ = await stalls.next()
        #expect(await eventually { store.resumableBytes(for: fake.model) > 0 })
        consumer.cancel()
        _ = try? await consumer.value

        #expect(await eventually { !store.isDownloading(fake.model) }, "cancellation must stop the download")
        #expect(!store.isDownloaded(fake.model))
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: fake.model).path))
        #expect(store.resumableBytes(for: fake.model) > 0)
    }

    @Test func droppingTheStreamCancelsTheDownload() async throws {
        let (store, transport) = store(.stallsAfter(20_000))
        do {
            let stream = store.download(fake.model)
            var stalls = transport.stalls.makeAsyncIterator()
            _ = await stalls.next()
            _ = stream
        }
        #expect(await eventually { !store.isDownloading(fake.model) })
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func resumesFromThePartialWithARangeRequest() async throws {
        let (first, _) = store(.dropsOnceAfter(30_000))
        await #expect(throws: LocalModelStoreError.failed(model: fake.model.name, reason: "The connection was lost.")) {
            try await drain(first.download(fake.model))
        }
        let kept = first.resumableBytes(for: fake.model)
        #expect(kept > 0)

        // A new store, as after the app was relaunched.
        let (second, transport) = store()
        try await drain(second.download(fake.model))
        #expect(second.isDownloaded(fake.model))
        for (path, data) in fake.files {
            #expect(try Data(contentsOf: second.directory(for: fake.model).appending(path: path)) == data)
        }
        // Files finished before the drop are not fetched again, and the one
        // cut off resumes where it stopped.
        let resumed = transport.requests.filter { $0.offset > 0 }
        #expect(resumed.map(\.path) == ["model.safetensors"])
        #expect(resumed.first?.offset == kept - 120, "config.json (120 bytes) was already complete")
        #expect(!transport.requests.contains { $0.path == "config.json" })
    }

    @Test func aServerThatIgnoresRangeIsStartedAgainNotAppended() async throws {
        let (first, _) = store(.dropsOnceAfter(30_000))
        _ = try? await drain(first.download(fake.model))
        #expect(first.resumableBytes(for: fake.model) > 0)

        let (second, transport) = store(.ignoresRange)
        try await drain(second.download(fake.model))
        #expect(second.isDownloaded(fake.model))
        #expect(transport.requests.contains { $0.offset > 0 }, "it asked to resume")
        let data = try Data(contentsOf: second.directory(for: fake.model).appending(path: "model.safetensors"))
        #expect(data == fake.files["model.safetensors"])
    }

    @Test func aSecondDownloadOfTheSameModelIsRefused() async throws {
        let (store, transport) = store(.stallsAfter(10_000))
        let first = store.download(fake.model)
        var stalls = transport.stalls.makeAsyncIterator()
        _ = await stalls.next()
        await #expect(throws: LocalModelStoreError.alreadyDownloading(model: fake.model.name)) {
            try await drain(store.download(fake.model))
        }
        try await store.delete(fake.model)
        _ = first
    }

    // MARK: - Failures

    @Test func aCorruptFileIsDiscardedAndTheModelIsNotInstalled() async throws {
        var files = fake.files
        var bad = files["model.safetensors"]!
        bad[100] ^= 0xFF
        files["model.safetensors"] = bad
        let transport = FakeModelTransport(files: files)
        let store = LocalModelStore(root: root, transport: transport, freeBytes: { _ in nil })

        await #expect(throws: LocalModelStoreError.corrupt(model: fake.model.name, file: "model.safetensors")) {
            try await drain(store.download(fake.model))
        }
        #expect(!store.isDownloaded(fake.model))
        let part = store.stagingDirectory(for: fake.model).appending(path: "model.safetensors.part")
        #expect(!FileManager.default.fileExists(atPath: part.path), "a damaged file must not be resumed")
    }

    @Test func aFileLongerThanPinnedIsCorrupt() async throws {
        var files = fake.files
        files["config.json"]! += Data([1, 2, 3])
        let store = LocalModelStore(root: root, transport: FakeModelTransport(files: files), freeBytes: { _ in nil })
        await #expect(throws: LocalModelStoreError.corrupt(model: fake.model.name, file: "config.json")) {
            try await drain(store.download(fake.model))
        }
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func anHTTPErrorIsReportedWithItsStatus() async throws {
        let (store, _) = store(.status(503))
        await #expect(throws: LocalModelStoreError.httpStatus(model: fake.model.name, file: "config.json",
                                                              status: 503)) {
            try await drain(store.download(fake.model))
        }
        #expect(!store.isDownloaded(fake.model))
    }

    @Test func aDroppedConnectionFailsAndKeepsWhatArrived() async throws {
        let (store, _) = store(.dropsOnceAfter(30_000))
        await #expect(throws: LocalModelStoreError.failed(model: fake.model.name, reason: "The connection was lost.")) {
            try await drain(store.download(fake.model))
        }
        #expect(!store.isDownloaded(fake.model))
        #expect(store.resumableBytes(for: fake.model) >= 30_000)
        #expect(LocalModelStoreError.interrupted(model: "X").errorDescription?.contains("continue") == true)
    }

    // MARK: - The disk check

    @Test func refusesToStartWithoutRoomAndFetchesNothing() async throws {
        let (store, transport) = store(freeBytes: 1_000_000)
        #expect(!store.diskCheck(for: fake.model).fits)
        await #expect(throws: LocalModelStoreError.self) { try await drain(store.download(fake.model)) }
        #expect(transport.requests.isEmpty)
        do {
            try await drain(store.download(fake.model))
        } catch let error as LocalModelStoreError {
            guard case let .notEnoughSpace(_, required, free) = error else {
                Issue.record("expected notEnoughSpace, got \(error)")
                return
            }
            #expect(required == fake.totalBytes)
            #expect(free == 1_000_000)
            #expect(error.errorDescription?.contains("Free up some space") == true)
        }
    }

    @Test func needsTheDownloadPlusHeadroom() {
        let total = fake.totalBytes
        let exact = LocalModelStore(root: root, freeBytes: { _ in total })
        #expect(!exact.diskCheck(for: fake.model).fits)
        let roomy = LocalModelStore(root: root, freeBytes: { _ in total + LocalDeviceStorage.headroomBytes })
        #expect(roomy.diskCheck(for: fake.model).fits)
        let unknown = LocalModelStore(root: root, freeBytes: { _ in nil })
        #expect(unknown.diskCheck(for: fake.model).fits)
        #expect(unknown.diskCheck(for: fake.model).freeBytes == nil)
    }

    @Test func countsOnlyWhatIsLeftToFetch() async throws {
        let (first, _) = store(.dropsOnceAfter(30_000))
        _ = try? await drain(first.download(fake.model))
        let kept = first.resumableBytes(for: fake.model)
        let check = first.diskCheck(for: fake.model)
        #expect(check.requiredBytes == fake.totalBytes - kept)

        let (done, _) = store()
        try await drain(done.download(fake.model))
        #expect(done.diskCheck(for: fake.model).requiredBytes == 0)
    }
}

// Where downloaded models live, and how they get there. Mirrors `isInstalled`,
// `install`, `uninstall`, `installedHere` and `fitsOnDisk` on `LocalModelChoice`
// in lib/src/services/inference/local_model_backend.dart, which delegated the
// storage itself to flutter_gemma.

import CryptoKit
import Foundation
import Synchronization

/// The downloaded models on this device.
///
/// Layout, under `root`:
///
///     <id>/                    a complete, verified model; MLX loads this
///       council-model.json     written last: id, repository, revision
///       config.json, model.safetensors, tokenizer.json, ...
///     .downloads/<id>/         a download in progress (or interrupted)
///       tokenizer.json         finished and verified
///       model.safetensors.part partial; resumed from its length
///
/// A model only appears at `<id>/` by renaming the whole staging directory
/// once every file has been received *and* has matched its size and SHA-256,
/// so an interrupted or corrupt download can never look installed. The Dart
/// leaned on flutter_gemma for this and still met a model that "downloads and
/// installs perfectly and then fails at the first question"; here the check
/// that a model is complete is the same check that it is intact.
///
/// The root is excluded from iCloud and device backups: the weights are
/// re-downloadable, large, and would otherwise count against the reader's
/// iCloud storage on every phone they own.
///
/// Thread-safe; one store per root is expected (the app makes one).
public final class LocalModelStore: Sendable {
    public let root: URL
    private let transport: any LocalModelTransport
    private let freeBytes: @Sendable (URL) -> Int64?
    /// The download task per model id, so a second download of the same model
    /// is refused and `delete` can stop one in progress.
    private let downloads = Mutex<[String: Task<Void, Never>]>([:])

    static let markerName = "council-model.json"
    static let stagingName = ".downloads"
    static let partSuffix = ".part"

    /// - Parameters:
    ///   - root: Usually `defaultRoot()`. Created on first download.
    ///   - transport: Tests inject one; the app uses the default.
    ///   - freeBytes: Free space on the volume holding a URL; injectable so the
    ///     disk check can be tested without filling a disk.
    public init(root: URL,
                transport: any LocalModelTransport = URLSessionModelTransport(),
                freeBytes: @escaping @Sendable (URL) -> Int64? = LocalDeviceStorage.freeBytes(at:)) {
        self.root = root
        self.transport = transport
        self.freeBytes = freeBytes
    }

    /// `MLXModels` in the app's Application Support directory: the same base
    /// as the corpus and user database (`AppModel.supportDirectory`), so on
    /// macOS under the bundle id. The Flutter app's `.litertlm` files were
    /// elsewhere and in a format MLX can't read; Phase 7 deletes them.
    ///
    /// - Parameter bundleIdentifier: The macOS subdirectory. Defaults to the
    ///   running bundle's id; a test run passes the app's, since its own
    ///   bundle is xctest's.
    public static func defaultRoot(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> URL {
        var base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        #if os(macOS)
        base = base.appending(path: bundleIdentifier ?? "site.spencersmith.council", directoryHint: .isDirectory)
        #endif
        return base.appending(path: "MLXModels", directoryHint: .isDirectory)
    }

    // MARK: - What is on disk

    /// Where `model` lives once downloaded; what MLX loads.
    public func directory(for model: LocalModel) -> URL {
        root.appending(path: model.id, directoryHint: .isDirectory)
    }

    func stagingDirectory(for model: LocalModel) -> URL {
        root.appending(path: Self.stagingName, directoryHint: .isDirectory)
            .appending(path: model.id, directoryHint: .isDirectory)
    }

    /// Whether `model` is downloaded, complete and of the revision the
    /// catalogue pins. Cheap (a few `stat`s), so fine to call while drawing.
    ///
    /// Hashes are checked when the download finishes, not here: rehashing
    /// gigabytes on every screen load would be absurd, and nothing but the
    /// reader deleting files by hand changes them afterwards. Sizes are
    /// checked, which catches that.
    public func isDownloaded(_ model: LocalModel) -> Bool {
        let directory = directory(for: model)
        guard let data = try? Data(contentsOf: directory.appending(path: Self.markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.id == model.id, marker.revision == model.revision
        else { return false }
        return model.files.allSatisfy { Self.fileSize(directory.appending(path: $0.path)) == $0.bytes }
    }

    /// Every catalogue model downloaded here (`installedHere`), including
    /// ones not offered on this device: a reader who has one must still be
    /// able to see and delete it.
    public func downloadedModels() -> [LocalModel] {
        LocalModel.catalogue.filter(isDownloaded)
    }

    /// Bytes `model` occupies, complete or partial: what deleting it frees.
    public func bytesOnDisk(for model: LocalModel) -> Int64 {
        Self.directorySize(directory(for: model)) + Self.directorySize(stagingDirectory(for: model))
    }

    /// Bytes of an interrupted download that a new one will keep rather than
    /// fetch again.
    public func resumableBytes(for model: LocalModel) -> Int64 {
        let staging = stagingDirectory(for: model)
        return model.files.reduce(0) { sum, file in
            let done = staging.appending(path: file.path)
            if Self.fileSize(done) == file.bytes { return sum + file.bytes }
            let part = Self.partURL(for: done)
            return sum + min(Self.fileSize(part) ?? 0, file.bytes)
        }
    }

    /// Whether a download of `model` is running in this process.
    public func isDownloading(_ model: LocalModel) -> Bool {
        downloads.withLock { $0[model.id] != nil }
    }

    /// Whether the rest of `model`'s download fits in the free space, with
    /// the 500 MB headroom the Dart keeps (`fitsOnDisk`). Counts only what is
    /// left to fetch, so a half-finished download isn't refused for space it
    /// already occupies.
    public func diskCheck(for model: LocalModel) -> LocalModelDiskCheck {
        let remaining = isDownloaded(model) ? 0 : model.downloadBytes - resumableBytes(for: model)
        let free = freeBytes(root)
        return LocalModelDiskCheck(requiredBytes: remaining, freeBytes: free,
                                   fits: LocalDeviceStorage.hasRoom(for: remaining, freeBytes: free))
    }

    /// Deletes `model`, complete or partial, stopping its download first if
    /// one is running.
    ///
    /// Half a gigabyte the reader can no longer account for is not something
    /// to leave on a phone with no way to remove it. Callers that may have
    /// the model loaded should go through `LocalModelBackend.delete()`, which
    /// unloads it first.
    public func delete(_ model: LocalModel) async throws {
        if let running = downloads.withLock({ $0[model.id] }) {
            running.cancel()
            await running.value
        }
        for directory in [directory(for: model), stagingDirectory(for: model)]
        where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Downloading

    /// Downloads `model`, streaming progress, and finishes once it is
    /// installed. Throws `LocalModelStoreError` on failure.
    ///
    /// Cancel by cancelling the consuming task or dropping the stream. The
    /// partial download is kept, and the next call resumes from it: files
    /// already verified are skipped and a partial file continues from its
    /// length with an HTTP `Range` request (the bytes already on disk are
    /// re-read to carry the hash forward). `delete` discards it.
    ///
    /// Progress is newest-wins: a consumer that falls behind sees the latest
    /// figure rather than a backlog.
    public func download(_ model: LocalModel) -> AsyncThrowingStream<LocalModelDownloadProgress, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: LocalModelDownloadProgress.self, bufferingPolicy: .bufferingNewest(1))

        let task = downloads.withLock { running -> Task<Void, Never>? in
            guard running[model.id] == nil else { return nil }
            let task = Task {
                do {
                    try await self.install(model) { continuation.yield($0) }
                    continuation.finish()
                } catch where error is CancellationError || Task.isCancelled {
                    // Including the URLError(.cancelled) a stopped request
                    // may surface as.
                    continuation.finish(throwing: CancellationError())
                } catch let error as LocalModelStoreError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LocalModelStoreError.failed(
                        model: model.name, reason: Self.describe(error)))
                }
                // Blocks until the enclosing `withLock` has returned, so the
                // entry is always there to remove.
                self.downloads.withLock { _ = $0.removeValue(forKey: model.id) }
            }
            running[model.id] = task
            return task
        }
        guard let task else {
            continuation.finish(throwing: LocalModelStoreError.alreadyDownloading(model: model.name))
            return stream
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    private func install(_ model: LocalModel, report: @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        let total = model.downloadBytes
        func progress(_ completed: Int64, _ phase: LocalModelDownloadProgress.Phase) {
            report(LocalModelDownloadProgress(modelID: model.id, completedBytes: completed,
                                              totalBytes: total, phase: phase))
        }

        if isDownloaded(model) {
            progress(total, .finished)
            return
        }
        progress(0, .preparing)

        let fm = FileManager.default
        let staging = stagingDirectory(for: model)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try excludeRootFromBackup()

        let check = diskCheck(for: model)
        guard check.fits else {
            throw LocalModelStoreError.notEnoughSpace(model: model.name, requiredBytes: check.requiredBytes,
                                                      freeBytes: check.freeBytes ?? 0)
        }

        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let destination = staging.appending(path: file.path)
            if Self.fileSize(destination) == file.bytes {
                completed += file.bytes
                continue
            }
            let base = completed
            try await fetch(file, from: model.url(for: file), to: destination, model: model) { received in
                progress(base + received, .downloading)
            }
            completed += file.bytes
            progress(completed, .downloading)
        }

        try Task.checkCancellation()
        let marker = try JSONEncoder().encode(Marker(id: model.id, repository: model.repository,
                                                     revision: model.revision))
        try marker.write(to: staging.appending(path: Self.markerName), options: .atomic)

        // The one step that makes the model visible. A stale copy (an older
        // revision the catalogue no longer pins) is replaced.
        let destination = directory(for: model)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
        let downloads = staging.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: downloads.path))?.isEmpty == true {
            try? fm.removeItem(at: downloads)
        }
        progress(total, .finished)
    }

    /// Fetches one file into `destination`, via `<destination>.part`.
    ///
    /// `received` is called with the bytes of this file on disk so far,
    /// at most every `progressStride` bytes.
    private func fetch(_ file: LocalModelFile, from url: URL, to destination: URL, model: LocalModel,
                       received: (Int64) -> Void) async throws {
        let fm = FileManager.default
        let part = Self.partURL(for: destination)
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)

        var offset = Self.fileSize(part) ?? 0
        if offset > file.bytes {
            try fm.removeItem(at: part)
            offset = 0
        }
        var hasher = SHA256()
        if offset > 0 {
            try Self.hash(part, into: &hasher)
            received(offset)
        }

        if offset < file.bytes {
            var handle: FileHandle?
            defer { try? handle?.close() }
            var lastReported = offset

            for try await event in transport.get(url, from: offset) {
                switch event {
                case .response(let status):
                    switch status {
                    case 206 where offset > 0:
                        handle = try FileHandle(forWritingTo: part)
                        try handle?.seekToEnd()
                    case 200:
                        // A server that ignores Range sends the whole file;
                        // start again rather than appending it.
                        fm.createFile(atPath: part.path, contents: nil)
                        handle = try FileHandle(forWritingTo: part)
                        offset = 0
                        hasher = SHA256()
                    default:
                        throw LocalModelStoreError.httpStatus(model: model.name, file: file.path, status: status)
                    }
                case .data(let data):
                    guard let handle else {
                        throw LocalModelStoreError.failed(model: model.name, reason: "The server sent no response.")
                    }
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    offset += Int64(data.count)
                    if offset > file.bytes {
                        try? fm.removeItem(at: part)
                        throw LocalModelStoreError.corrupt(model: model.name, file: file.path)
                    }
                    if offset - lastReported >= Self.progressStride {
                        lastReported = offset
                        received(offset)
                    }
                }
            }
            // A cancelled consumer ends the stream without an error; make it
            // one, so a cancelled download isn't mistaken for a short one.
            try Task.checkCancellation()
            try handle?.synchronize()
        }

        guard offset == file.bytes else {
            // Kept: the next attempt resumes from here.
            throw LocalModelStoreError.interrupted(model: model.name)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            try? fm.removeItem(at: part)
            throw LocalModelStoreError.corrupt(model: model.name, file: file.path)
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: part, to: destination)
    }

    /// How often progress is reported within a file. A UI needs nothing
    /// finer, and a 4.6 GB file arrives in hundreds of thousands of chunks.
    static let progressStride: Int64 = 1_048_576

    private func excludeRootFromBackup() throws {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    // MARK: - Helpers

    private struct Marker: Codable {
        let id: String
        let repository: String
        let revision: String
    }

    static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: destination.lastPathComponent + partSuffix)
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Carries a resumed file's hash over the bytes already on disk.
    static func hash(_ url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "The connection was lost."
            case .timedOut:
                return "The connection stopped responding."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// The disk check for one model's download.
public struct LocalModelDiskCheck: Sendable, Hashable {
    /// What is left to fetch.
    public let requiredBytes: Int64
    /// Nil when free space couldn't be read; `fits` is then true.
    public let freeBytes: Int64?
    /// Whether `requiredBytes` fits with `LocalDeviceStorage.headroomBytes`
    /// to spare.
    public let fits: Bool
}

/// Where a download has got to.
public struct LocalModelDownloadProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Checking what an earlier attempt left, including re-reading a
        /// partial file to resume its hash.
        case preparing
        case downloading
        /// Verified and in place; `isDownloaded` is now true.
        case finished
    }

    public let modelID: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let phase: Phase

    public init(modelID: String, completedBytes: Int64, totalBytes: Int64, phase: Phase) {
        self.modelID = modelID
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.phase = phase
    }

    /// 0...1.
    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }

    /// 0...100, as the Dart's `install()` stream reported it.
    public var percent: Int { Int((fraction * 100).rounded(.down)) }
}

/// Why a download failed, worded for the reader.
public enum LocalModelStoreError: LocalizedError, Sendable, Hashable {
    case notEnoughSpace(model: String, requiredBytes: Int64, freeBytes: Int64)
    case alreadyDownloading(model: String)
    case httpStatus(model: String, file: String, status: Int)
    /// A file didn't match its pinned size or hash; it was discarded.
    case corrupt(model: String, file: String)
    /// The connection ended early; what arrived is kept for resuming.
    case interrupted(model: String)
    case failed(model: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .notEnoughSpace(model, required, free):
            "\(model) needs \(LocalModelFormat.size(required + LocalDeviceStorage.headroomBytes)) free to "
                + "download, and this device has \(LocalModelFormat.size(free)). Free up some space and try again."
        case let .alreadyDownloading(model):
            "\(model) is already downloading."
        case let .httpStatus(model, file, status):
            "Could not download \(model): the server answered \(status) for \(file). Try again later."
        case let .corrupt(model, file):
            "Could not download \(model): \(file) arrived damaged and was discarded. Try again."
        case let .interrupted(model):
            "The download of \(model) was interrupted. Try again to continue where it stopped."
        case let .failed(model, reason):
            "Could not download \(model): \(reason) Try again to continue where it stopped."
        }
    }
}

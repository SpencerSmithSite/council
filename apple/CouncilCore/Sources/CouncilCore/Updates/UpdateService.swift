// Ported from lib/src/services/updates/update_service.dart; its tests from
// test/update_service_test.dart (`UpdateServiceTests`).

import CryptoKit
import Foundation
import os

/// What went wrong with a download. The messages are the Dart's
/// `UpdateException` texts, shown to the reader as they are.
public enum UpdateError: Error, Equatable, Sendable, LocalizedError {
    /// A store release was asked to download.
    case notADownload
    case notEnoughSpace(megabytes: Int)
    /// No response within `UpdateEndpoints.checkTimeout`.
    case startTimedOut
    case couldNotStart(String)
    case httpStatus(Int)
    /// Nothing arrived for `UpdateEndpoints.chunkTimeout`.
    case stalled
    case failed(String)
    case noChecksum
    case checksumMismatch
    /// The reader stopped it. Separate so the UI can go quiet instead of
    /// showing an error for something they asked for (Dart's
    /// `UpdateCancelled`).
    case cancelled

    public var message: String {
        switch self {
        case .notADownload:
            "This platform installs updates elsewhere."
        case .notEnoughSpace(let megabytes):
            "There is not enough free space for the \(megabytes) MB download. Free some up and try again."
        case .startTimedOut:
            "Could not start the download: the connection timed out."
        case .couldNotStart(let reason):
            "Could not start the download: \(reason)"
        case .httpStatus(let status):
            "Download failed (HTTP \(status))."
        case .stalled:
            "The download stalled and was stopped."
        case .failed(let reason):
            "The download failed: \(reason)"
        case .noChecksum:
            "That release was published without a checksum, so it was not installed."
        case .checksumMismatch:
            "The download did not match its checksum and was discarded. Check your connection and try again."
        case .cancelled:
            "The download was cancelled."
        }
    }

    public var errorDescription: String? { message }
}

/// A newer release for this platform, with what the manifest says about it.
public struct AvailableUpdate: Sendable, Hashable {
    public let release: PlatformRelease
    /// The release-wide "what changed" line, when there is one.
    public let notes: String?
    /// The download page.
    public let page: URL?

    public init(release: PlatformRelease, notes: String? = nil, page: URL? = nil) {
        self.release = release
        self.notes = notes
        self.page = page
    }
}

/// Finds out whether a newer Council exists, fetches it, and proves it is
/// genuine before anything is run.
///
/// Every method does its work off the main actor: the package compiles
/// nonisolated async functions to run on the global executor, so the fetch,
/// the file writes and the hashing never touch the UI's thread.
public final class UpdateService: Sendable {
    public let currentVersion: AppVersion
    /// Where downloads are staged: an `updates` folder in the app's own
    /// support directory, never Downloads, because every attempt deletes what
    /// it finds there and must never be in a position to delete something the
    /// reader put there (Dart's `stagingDirectory`).
    public let stagingDirectory: URL

    private let transport: any HTTPTransport
    private let manifestURL: URL
    private let platform: String
    private let freeBytes: @Sendable (URL) -> Int64?
    private let checkTimeout: Duration
    private let chunkTimeout: Duration

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Updates")

    /// - Parameters:
    ///   - current: The running build (`AppVersion.running()`).
    ///   - stagingDirectory: Created on demand.
    ///   - transport: Defaults to `UpdateDownloadTransport`.
    ///   - platform: The manifest key to read; `ReleaseManifest.currentPlatform`.
    ///   - freeBytes: Free space on the volume holding a URL; a test seam.
    public init(
        current: AppVersion,
        stagingDirectory: URL,
        transport: any HTTPTransport = UpdateDownloadTransport(),
        manifestURL: URL = UpdateEndpoints.manifestURL,
        platform: String = ReleaseManifest.currentPlatform,
        freeBytes: @escaping @Sendable (URL) -> Int64? = { LocalDeviceStorage.freeBytes(at: $0) },
        checkTimeout: Duration = UpdateEndpoints.checkTimeout,
        chunkTimeout: Duration = UpdateEndpoints.chunkTimeout
    ) {
        currentVersion = current
        self.stagingDirectory = stagingDirectory
        self.transport = transport
        self.manifestURL = manifestURL
        self.platform = platform
        self.freeBytes = freeBytes
        self.checkTimeout = checkTimeout
        self.chunkTimeout = chunkTimeout
    }

    // MARK: - Checking

    /// The published manifest, or nil when it couldn't be fetched or made
    /// sense of.
    ///
    /// Never throws. This runs unprompted at launch, and a reader with no
    /// network, or a site being redeployed, should see nothing at all rather
    /// than an error about a thing they didn't ask for.
    public func fetchManifest() async -> ReleaseManifest? {
        // A cached copy would hide the release that was just published.
        let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        do {
            let transport = self.transport
            let reply = try await withTimeLimit(checkTimeout) { () async throws -> (Int, Data) in
                let response = try await transport.send(request)
                return (response.statusCode, try await response.collect())
            }
            guard let (status, body) = reply else {
                Self.logger.info("Update check timed out")
                return nil
            }
            guard status == 200 else { return nil }
            return try ReleaseManifest.parse(body)
        } catch {
            Self.logger.info("Update check failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The release to offer, or nil when this build is current, the platform
    /// publishes no releases, or the check failed.
    public func check() async -> AvailableUpdate? {
        guard let manifest = await fetchManifest(), let release = manifest.platforms[platform] else {
            return nil
        }
        guard release.version > currentVersion else { return nil }
        return AvailableUpdate(release: release, notes: manifest.notes, page: manifest.page)
    }

    // MARK: - Downloading

    /// Removes whatever earlier attempts left in the staging folder. Files
    /// only, as in the Dart. Housekeeping, so never worth failing over.
    public func clearStaging() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? manager.removeItem(at: entry)
        }
    }

    /// Fetches `release` and returns the verified file.
    ///
    /// The file it returns has been checked against the manifest's SHA-256; no
    /// caller should ever run one that hasn't. Cancel by cancelling the calling
    /// task, which throws `.cancelled` and leaves nothing behind; each call
    /// starts afresh, so a cancelled attempt never spoils the next one.
    ///
    /// - Parameter progress: Bytes received and the total expected (the
    ///   manifest's exact size), from whatever thread the bytes arrive on.
    public func download(
        _ release: PlatformRelease,
        progress: @escaping @Sendable (_ received: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws(UpdateError) -> URL {
        guard release.delivery == .download else { throw .notADownload }

        // Asked before the bytes rather than after: the model download taught
        // this exact lesson, where a full fetch failed at the install step on
        // a device that never had room for it (Dart's comment).
        let room = Int64(release.megabytes) * 1_048_576
        guard LocalDeviceStorage.hasRoom(for: room, freeBytes: freeBytes(stagingDirectory)) else {
            throw .notEnoughSpace(megabytes: release.megabytes)
        }

        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw .failed(error.localizedDescription)
        }
        clearStaging()
        let destination = stagingDirectory.appending(path: release.fileName, directoryHint: .notDirectory)

        do {
            try await fetch(release, to: destination, progress: progress)
        } catch {
            discard(destination)
            throw Self.classify(error)
        }

        try verify(release, file: destination)
        return destination
    }

    /// Streams the body to `destination`, under a watchdog that allows
    /// `checkTimeout` for the response to start and then `chunkTimeout`
    /// between pieces: Dart's `send(...).timeout(checkTimeout)` followed by
    /// `stream.timeout(chunkTimeout)`.
    private func fetch(_ release: PlatformRelease, to destination: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let request = URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData)
        let transport = self.transport
        let total = release.bytes ?? 0
        let watchdog = Watchdog(first: checkTimeout, idle: chunkTimeout)
        try await watchdog.run(timeout: { phase in
            phase == .first ? UpdateError.startTimedOut : UpdateError.stalled
        }) {
            let response: HTTPStreamResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw UpdateError.couldNotStart(error.localizedDescription)
            }
            watchdog.touch()
            guard response.statusCode == 200 else { throw UpdateError.httpStatus(response.statusCode) }

            // Streamed to disk rather than buffered.
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw UpdateError.failed("could not create \(destination.lastPathComponent)")
            }
            let sink = try FileHandle(forWritingTo: destination)
            defer { try? sink.close() }
            var received = 0
            for try await chunk in response.body {
                try Task.checkCancellation()
                try sink.write(contentsOf: chunk)
                received += chunk.count
                watchdog.touch()
                progress(received, total)
            }
            // A cancelled iteration can end quietly rather than throw; a
            // truncated file must not pass for a finished one.
            try Task.checkCancellation()
        }
    }

    private static func classify(_ error: any Error) -> UpdateError {
        switch error {
        case let error as UpdateError: error
        case is CancellationError: .cancelled
        case let error as URLError where error.code == .cancelled: .cancelled
        default: .failed(error.localizedDescription)
        }
    }

    /// Rejects anything whose bytes are not the ones the manifest published.
    ///
    /// The strictest step, and the reason the manifest carries a checksum at
    /// all: what this returns is installed and run with the reader's own
    /// privileges. A truncated download, a proxy serving something else, a
    /// connection resumed against a different file: none should get that far,
    /// and the app can't tell them from a genuine installer except by this.
    private func verify(_ release: PlatformRelease, file: URL) throws(UpdateError) {
        guard let expected = release.sha256 else {
            discard(file)
            throw .noChecksum
        }
        let digest: String
        do {
            digest = try Self.sha256(of: file)
        } catch {
            discard(file)
            throw .failed(error.localizedDescription)
        }
        guard digest == expected else {
            discard(file)
            throw .checksumMismatch
        }
    }

    /// Lower-case hex SHA-256 of a file, read a megabyte at a time.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}

/// `URLSession` behind `HTTPTransport`, for an installer.
///
/// Not `URLSessionTransport`, which hands its body over a line at a time for
/// the chat protocols: a disk image has a newline byte every few hundred
/// bytes, so that would be hundreds of thousands of pieces. This hands over
/// 256 KB at a time.
public struct UpdateDownloadTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // `UpdateService` polices the timing itself; these only stop
            // URLSession giving up first.
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 6 * 60 * 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    let size = 256 * 1024
                    var buffer = Data(capacity: size)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count == size {
                            continuation.yield(buffer)
                            buffer = Data(capacity: size)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: status, body: body)
    }
}

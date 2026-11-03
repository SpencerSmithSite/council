// Ported from the HTTP half of lib/src/services/packs/pack_service.dart
// (`fetchManifest`, `_download`, `networkTimeout`, `downloadTimeout`).

import Foundation

/// How `PackService` reaches the published release.
///
/// A protocol so tests can serve the fixture files in shared/golden/packs and
/// exercise download, checksum, gunzip and merge together with only the socket
/// replaced, as the Flutter test does with `MockClient`.
public protocol PackFetcher: Sendable {
    /// GET `url` into memory, for the manifest.
    ///
    /// Returns the HTTP status and body whatever the status; the caller
    /// decides what a non-200 means. Throws `PackFetcherError.timedOut` when
    /// no answer arrives in time.
    func get(_ url: URL) async throws -> (status: Int, body: Data)

    /// GET `url` streamed into `destination`, for a fragment.
    ///
    /// Returns the HTTP status. The body is written, replacing `destination`,
    /// only when the status is 200; `progress` is called with the bytes
    /// received so far as they arrive. Throws `PackFetcherError.timedOut` when
    /// the response does not *start* in time; a transfer that stalls later
    /// throws whatever the transport throws (Dart surfaces a raw
    /// `TimeoutException` there too).
    func download(_ url: URL, to destination: URL, progress: @Sendable (Int) -> Void) async throws -> Int
}

public enum PackFetcherError: Error, Equatable, Sendable {
    /// No response arrived in time. `PackService` turns this into the
    /// `PackError` naming what was being fetched.
    case timedOut
}

/// The real fetcher, over `URLSession`.
public struct URLSessionPackFetcher: PackFetcher {
    /// How long to wait for an answer before calling the release unreachable.
    ///
    /// Without this the request has no deadline at all, and a connection that
    /// hangs rather than fails leaves the onboarding screen on a spinner
    /// forever — no error, no retry. Observed on the iOS 27 simulator, where
    /// the request neither completed nor raised. The screen already knows how
    /// to say the catalogue is unreachable and offer to try again; it simply
    /// never got the chance, because a hang is not an error until something
    /// decides it is.
    ///
    /// Applied as `URLRequest.timeoutInterval`, which URLSession treats as the
    /// longest silence it will tolerate rather than a deadline for the whole
    /// response. For a hang, the case this exists for, the two are the same.
    public static let networkTimeout: TimeInterval = 20

    /// Longer, because this one covers a multi-megabyte body on a phone
    /// connection. It has to accommodate the largest fragment — 33.9 MB — over
    /// a slow link. Applied as the session's resource timeout, which bounds the
    /// whole transfer.
    public static let downloadTimeout: TimeInterval = 10 * 60

    private let session: URLSession

    /// - Parameter session: Defaults to a session carrying the two timeouts
    ///   above that never answers from its cache. A caller passing its own
    ///   session owns its resource timeout and caching.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.networkTimeout
            config.timeoutIntervalForResource = Self.downloadTimeout
            // A republished fragment keeps its URL; a cached copy of the old
            // file would fail its checksum for no reason the reader can fix.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: URL) async throws -> (status: Int, body: Data) {
        let (body, response) = try await timingOut {
            try await session.data(for: request(url))
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    public func download(_ url: URL, to destination: URL, progress: @Sendable (Int) -> Void) async throws -> Int {
        let (bytes, response) = try await timingOut {
            try await session.bytes(for: request(url))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return status }

        // Streamed to disk rather than buffered: holding a fragment in memory
        // and then its expanded copy as well is avoidable on a phone.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        let flushAt = 64 * 1024
        var buffer = [UInt8]()
        buffer.reserveCapacity(flushAt)
        var received = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == flushAt {
                try sink.write(contentsOf: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                progress(received)
            }
        }
        if !buffer.isEmpty {
            try sink.write(contentsOf: buffer)
            received += buffer.count
            progress(received)
        }
        return status
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.networkTimeout
        return request
    }

    private func timingOut<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where error.code == .timedOut {
            throw PackFetcherError.timedOut
        }
    }
}

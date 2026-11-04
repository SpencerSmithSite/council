import CryptoKit
import Foundation
import Synchronization
@testable import CouncilCore

/// Serves model files from memory, for `LocalModelStore` tests. No sockets.
///
/// Can ignore `Range` (as a misbehaving server would), drop the connection
/// after so many bytes, or stall after so many bytes until cancelled.
final class FakeModelTransport: LocalModelTransport {
    struct Request: Sendable, Equatable {
        let path: String
        let offset: Int64
    }

    enum Behaviour: Sendable {
        case normal
        /// Answers 200 with the whole file whatever `Range` asks for.
        case ignoresRange
        /// The first request for a file fails after this many body bytes.
        case dropsOnceAfter(Int)
        /// Every request stalls after this many body bytes until cancelled.
        case stallsAfter(Int)
        /// Answers this status with no body.
        case status(Int)
    }

    let files: [String: Data]
    let behaviour: Behaviour
    let chunkSize: Int
    private let log = Mutex<[Request]>([])
    private let dropped = Mutex<Set<String>>([])
    /// Yields each time a request stalls.
    let stalls: AsyncStream<Void>
    private let stalled: AsyncStream<Void>.Continuation

    init(files: [String: Data], behaviour: Behaviour = .normal, chunkSize: Int = 4096) {
        self.files = files
        self.behaviour = behaviour
        self.chunkSize = chunkSize
        (stalls, stalled) = AsyncStream.makeStream()
    }

    var requests: [Request] { log.withLock { $0 } }

    func get(_ url: URL, from offset: Int64) -> AsyncThrowingStream<LocalModelTransportEvent, any Error> {
        let path = url.lastPathComponent
        log.withLock { $0.append(Request(path: path, offset: offset)) }
        let body = files[path]
        let behaviour = behaviour
        let chunkSize = chunkSize
        let firstForPath = dropped.withLock { $0.insert(path).inserted }
        let stalled = stalled

        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let body else {
                    continuation.yield(.response(status: 404))
                    continuation.finish()
                    return
                }
                if case .status(let status) = behaviour {
                    continuation.yield(.response(status: status))
                    continuation.finish()
                    return
                }
                var start = Int(offset)
                if case .ignoresRange = behaviour { start = 0 }
                continuation.yield(.response(status: start > 0 ? 206 : 200))

                var sent = 0
                var position = start
                while position < body.count {
                    if Task.isCancelled { break }
                    if case .stallsAfter(let limit) = behaviour, sent >= limit {
                        stalled.yield()
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                        break
                    }
                    if case .dropsOnceAfter(let limit) = behaviour, firstForPath, sent >= limit {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                        return
                    }
                    let end = min(position + chunkSize, body.count)
                    continuation.yield(.data(body.subdata(in: position..<end)))
                    sent += end - position
                    position = end
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A small model whose files are generated in memory, with real hashes, so
/// the store's verification runs for real.
struct FakeModel {
    let model: LocalModel
    let files: [String: Data]

    init(id: String = "fake-model", sizes: [String: Int] = [
        "config.json": 120, "model.safetensors": 60_000, "tokenizer.json": 9_000,
    ], revision: String = String(repeating: "a", count: 40)) {
        var generator = SystemRandomNumberGenerator()
        var files: [String: Data] = [:]
        var entries: [LocalModelFile] = []
        for (path, size) in sizes.sorted(by: { $0.key < $1.key }) {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
            files[path] = data
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entries.append(LocalModelFile(path: path, bytes: Int64(size), sha256: digest))
        }
        self.files = files
        model = LocalModel(id: id, name: "Fake \(id)", repository: "test/\(id)", revision: revision,
                           files: entries, ramMB: 100, minDeviceRAMMB: 1000, minPhoneRAMMB: 1000,
                           maxTokens: 512, contextBudgetChars: 1000, thinksByDefault: true, note: "")
    }

    var totalBytes: Int64 { model.downloadBytes }
}

/// A fresh temporary directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LocalModelTests-\(UUID().uuidString)",
                                                              directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls `condition` until true or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

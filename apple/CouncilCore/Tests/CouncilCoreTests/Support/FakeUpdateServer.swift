import CryptoKit
import Foundation
import Synchronization
@testable import CouncilCore

/// Serves `updates.json` and an installer, as the Dart tests' `MockClient`
/// does: the manifest for any URL ending `updates.json`, the installer for
/// anything else, in small pieces so progress has something to report.
final class FakeUpdateServer: HTTPTransport {
    struct Config: Sendable {
        var manifest = ""
        var manifestStatus = 200
        var installer = Data()
        var installerStatus = 200
        var chunkSize = 8 * 1024
        /// The installer's body comes from here instead, for a test that feeds
        /// it by hand.
        var installerStream: AsyncThrowingStream<Data, any Error>?
        var hangBeforeHeaders = false
        var hangAfterChunks = false
    }

    private let state: Mutex<(config: Config, requests: [URL])>

    init(_ config: Config) {
        state = Mutex((config, []))
    }

    var requests: [URL] { state.withLock { $0.requests } }
    var installerRequests: Int { requests.filter { !$0.path.hasSuffix("updates.json") }.count }

    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let url = request.url!
        let config = state.withLock {
            $0.requests.append(url)
            return $0.config
        }
        if config.hangBeforeHeaders { try await Task.sleep(for: .seconds(3600)) }
        if url.path.hasSuffix("updates.json") {
            let body = Data(config.manifest.utf8)
            return HTTPStreamResponse(statusCode: config.manifestStatus,
                                      body: AsyncThrowingStream { $0.yield(body); $0.finish() })
        }
        if let stream = config.installerStream {
            return HTTPStreamResponse(statusCode: config.installerStatus, body: stream)
        }
        let bytes = config.installer
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + config.chunkSize, bytes.count)
                    continuation.yield(bytes.subdata(in: offset..<end))
                    offset = end
                    await Task.yield()
                }
                if config.hangAfterChunks { try? await Task.sleep(for: .seconds(3600)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: config.installerStatus, body: body)
    }
}

/// The Dart tests' installer and manifest.
enum UpdateFixtures {
    static let installer = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every platform, as the Dart test writes it, so the service finds the one
    /// it is told to read.
    static func manifest(version: String = "2026.8.2", build: Int = 7, sha: String? = nil,
                         bytes: Int? = nil, installer: Data = installer, notes: String? = nil) -> String {
        var platforms: [String: Any] = [:]
        for id in ["android", "macos", "windows", "linux"] {
            platforms[id] = [
                "kind": "download",
                "url": "https://example.com/v\(version)/Council-\(id).bin",
                "bytes": bytes ?? installer.count,
                "sha256": sha ?? sha256(installer),
            ]
        }
        platforms["ios"] = ["kind": "store", "url": "https://testflight.apple.com/join/JZ1k29YE"]
        var json: [String: Any] = ["schema": 1, "version": version, "build": build, "platforms": platforms,
                                   "url": "https://www.spencersmith.site/council/download.html"]
        if let notes { json["notes"] = notes }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func temporaryDirectory(_ name: String = "council-update-test") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

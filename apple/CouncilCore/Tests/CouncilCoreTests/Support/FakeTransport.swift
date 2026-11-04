import Foundation
import Synchronization
@testable import CouncilCore

/// An `HTTPTransport` that replies from a script, split wherever the test
/// says. Where the chunk boundaries fall is the whole subject of a streaming
/// parser's tests, so a fake that chose them itself would test nothing.
///
/// Each `send` takes the next reply in the script (the last one repeats), and
/// records the request.
final class FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var chunks: [Data] = []
        /// Thrown by `send` itself, before any headers.
        var sendError: (any Error)?
        /// Thrown by the body after its chunks.
        var bodyError: (any Error)?
        /// Never send the headers.
        var hangBeforeHeaders = false
        /// After the chunks, neither finish nor fail.
        var hangAfterChunks = false

        static func body(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, chunks: [Data(text.utf8)])
        }

        static func chunks(_ pieces: [String], status: Int = 200) -> Reply {
            Reply(status: status, chunks: pieces.map { Data($0.utf8) })
        }

        /// One byte per chunk: every multi-byte character and every line is
        /// split.
        static func bytewise(_ text: String) -> Reply {
            Reply(chunks: text.utf8.map { Data([$0]) })
        }

        static func failing(_ error: any Error) -> Reply {
            Reply(sendError: error)
        }
    }

    private struct State {
        var replies: [Reply]
        var requests: [URLRequest] = []
        var bodyTerminations = 0
    }

    private let state: Mutex<State>

    init(_ replies: Reply...) {
        state = Mutex(State(replies: replies))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// How many reply bodies have been terminated (finished, failed or
    /// cancelled by the consumer).
    var bodyTerminations: Int { state.withLock { $0.bodyTerminations } }

    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let reply = state.withLock {
            $0.requests.append(request)
            return $0.replies.count > 1 ? $0.replies.removeFirst() : $0.replies[0]
        }
        if let error = reply.sendError { throw error }
        if reply.hangBeforeHeaders {
            try await Task.sleep(for: .seconds(3600))
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for chunk in reply.chunks {
                    continuation.yield(chunk)
                    await Task.yield()
                }
                if reply.hangAfterChunks {
                    try? await Task.sleep(for: .seconds(3600))
                    return
                }
                if let error = reply.bodyError {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.state.withLock { $0.bodyTerminations += 1 }
            }
        }
        return HTTPStreamResponse(statusCode: reply.status, body: body)
    }
}

extension URLRequest {
    /// The body as text.
    var bodyText: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// Collects a stream, returning what arrived and the error it ended with.
func drain(_ stream: AsyncThrowingStream<String, any Error>) async -> (pieces: [String], error: (any Error)?) {
    var pieces: [String] = []
    do {
        for try await piece in stream { pieces.append(piece) }
        return (pieces, nil)
    } catch {
        return (pieces, error)
    }
}

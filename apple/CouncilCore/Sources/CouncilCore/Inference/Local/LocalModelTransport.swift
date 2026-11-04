// How model files are fetched. Replaces flutter_gemma's `installModel()
// .fromNetwork(url)` in lib/src/services/inference/local_model_backend.dart,
// which owned the HTTP itself.

import Foundation

/// One step of a streamed GET: the response arrives once, then the body in
/// chunks.
public enum LocalModelTransportEvent: Sendable {
    /// The HTTP status. 206 means the `Range` asked for was honoured and the
    /// body continues from that offset; 200 means the body starts from byte 0
    /// whatever was asked for.
    case response(status: Int)
    case data(Data)
}

/// How `LocalModelStore` reaches Hugging Face.
///
/// A protocol so tests can serve files from memory, honour or ignore `Range`,
/// fail halfway or hang, all without a socket (the same seam as
/// `PackFetcher`). Chunks rather than a file: the store hashes and writes as
/// bytes arrive, so a multi-gigabyte file is never held in memory or read
/// back twice.
public protocol LocalModelTransport: Sendable {
    /// GET `url`, asking for the body from byte `offset` on when it is above
    /// zero. Yields `.response` first, then `.data` until the body ends.
    /// Cancelling the consumer (or dropping the stream) must stop the request.
    func get(_ url: URL, from offset: Int64) -> AsyncThrowingStream<LocalModelTransportEvent, any Error>
}

/// The real transport, over `URLSession`.
///
/// A data task with its own delegate rather than `URLSession.bytes(for:)`:
/// the async byte sequence hands over one byte at a time, which for a
/// 4.6 GB file is billions of iterations, while the delegate receives the
/// chunks the network delivered. A data task rather than a download task:
/// download tasks resume only from opaque resume data that doesn't survive
/// the app being relaunched, whereas a `.part` file and a `Range` header do.
public final class URLSessionModelTransport: LocalModelTransport {
    /// The longest silence tolerated before the request is called failed.
    /// Not a deadline for the whole file: a large model on a slow phone
    /// connection legitimately takes an hour, and a partial download is kept
    /// for resuming whenever it stops.
    public static let silenceTimeout: TimeInterval = 60

    private let session: URLSession

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.silenceTimeout
            // The files are addressed by commit and never change, but a
            // cached 200 for a Range request would be wrong; the cache would
            // also hold a second copy of gigabytes.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            return config
        }()
        session = URLSession(configuration: config)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func get(_ url: URL, from offset: Int64) -> AsyncThrowingStream<LocalModelTransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            var request = URLRequest(url: url)
            if offset > 0 {
                // Hugging Face answers /resolve/ with a redirect to its CDN;
                // URLSession carries this header across the redirect.
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            let task = session.dataTask(with: request)
            task.delegate = StreamingDelegate(continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}

/// Forwards one data task's callbacks into its stream. URLSession calls a
/// task's delegate serially, and the continuation is itself thread-safe, so
/// there is no state here to protect.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let continuation: AsyncThrowingStream<LocalModelTransportEvent, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<LocalModelTransportEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.response(status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

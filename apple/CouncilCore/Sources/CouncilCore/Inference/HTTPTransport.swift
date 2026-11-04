// The HTTP seam the Ollama and cloud backends talk through, and the pieces of
// streaming they share: whole-line reassembly (lib/src/util/stream_lines.dart,
// test/stream_lines_test.dart), timeouts, and recognising a dropped
// connection.

import Foundation
import Synchronization

/// A response whose body arrives in pieces.
public struct HTTPStreamResponse: Sendable {
    public let statusCode: Int
    /// The body, in whatever pieces the network delivers. Ends when the body
    /// does; throws if the connection fails partway. Cancelling the consumer
    /// cancels the request.
    public let body: AsyncThrowingStream<Data, any Error>

    public init(statusCode: Int, body: AsyncThrowingStream<Data, any Error>) {
        self.statusCode = statusCode
        self.body = body
    }

    /// The whole body. For error bodies and small JSON replies.
    public func collect() async throws -> Data {
        var data = Data()
        for try await piece in body { data.append(piece) }
        return data
    }
}

/// Sends a request and hands back the status as soon as the headers arrive,
/// with the body still streaming.
///
/// A protocol rather than `URLSession` directly so tests can feed the parsers
/// recorded responses split wherever the test chooses: chunk boundaries are
/// the whole difficulty of parsing a stream, and a test that can't choose
/// where they fall can't check it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// `URLSession.bytes(for:)` behind `HTTPTransport`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    // Delivered a line at a time (both protocols here are
                    // line-delimited, so a token reaches the screen as soon as
                    // its line is complete), or every 4 KB of a line that runs
                    // on.
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the iteration cancels the URLSession task, which
            // closes the connection: a stopped answer stops costing the
            // reader's cloud account or the Ollama host's GPU.
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: status, body: body)
    }
}

/// Re-assembles a chunked byte stream into whole lines (Dart's `wholeLines`).
///
/// Both streaming backends read a line-delimited protocol over HTTP (Ollama's
/// NDJSON and the cloud providers' Server-Sent Events) and a socket knows
/// nothing about either. A chunk boundary falls wherever the network put it,
/// routinely in the middle of a line, and the two halves aren't parseable as
/// anything. Splitting each chunk on its own and skipping whatever fails to
/// parse looks as if it works, and quietly loses a word here and there: the
/// reader gets a fluent sentence with a hole in it.
///
/// Splits on the `\n` byte and decodes each line as UTF-8. That is the same
/// as Dart's decode-then-split, because `\n` never occurs inside a multi-byte
/// UTF-8 sequence, and it means a character split across chunks is never
/// decoded in halves. A `\r` before the `\n` stays on the line, as in Dart;
/// the parsers trim it. A trailing fragment with no closing newline is
/// emitted when the stream ends, so a server that doesn't terminate its last
/// line doesn't lose it either.
struct LineAssembler {
    private var buffer: [UInt8] = []

    /// The lines completed by `chunk`.
    mutating func feed(_ chunk: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 0x0A {
                lines.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }

    /// The unterminated last line, if there is one.
    mutating func finish() -> String? {
        defer { buffer = [] }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

/// Classifies transport errors.
enum TransportFailure {
    /// Whether `error` looks like a connection that dropped, was refused or
    /// never got going, rather than a reply from the server.
    ///
    /// Two Dart checks map onto this one: Ollama's `_looksLikeColdStart`
    /// (any `SocketException`, or "connection reset/abort/closed/terminated",
    /// "software caused") and the chat screen's `_friendlyError` (the same,
    /// plus "connection refused"). `URLError` reports those conditions as the
    /// codes below; a bare POSIX error can also surface from the socket layer.
    static func isConnectionDrop(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .notConnectedToInternet, .timedOut:
                return true
            default:
                return false
            }
        }
        if let error = error as? POSIXError {
            switch error.code {
            case .ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .EPIPE, .ENOTCONN, .ETIMEDOUT:
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Fails an operation that goes quiet for too long.
///
/// Allows `first` until the first `touch()`, then `idle` between touches. An
/// answer may take as long as it likes so long as it is still arriving; what
/// this catches is a network that completes the handshake and then swallows
/// the request (a captive portal, a proxy holding the connection), or a
/// backend that accepts a request and never says anything. Without a bound,
/// whatever waits on such a stream waits forever.
///
/// Generic over the clock so tests can drive time by hand: wall-clock tests
/// of "slow but steady is fine" fail whenever the machine is busy enough to
/// starve a sleeping task.
final class Watchdog<C: Clock>: Sendable where C.Duration == Duration, C: Sendable {
    private struct State {
        var last: C.Instant
        var touched = false
    }

    private let first: Duration
    private let idle: Duration
    private let clock: C
    private let state: Mutex<State>

    init(first: Duration, idle: Duration, clock: C) {
        self.first = first
        self.idle = idle
        self.clock = clock
        state = Mutex(State(last: clock.now))
    }

    /// Something arrived: restart the clock, with the idle allowance from now
    /// on.
    func touch() {
        state.withLock {
            $0.last = clock.now
            $0.touched = true
        }
    }

    /// Runs `body`, cancelling it and throwing `timeout(phase)` if it goes
    /// quiet for longer than allowed. `body` calls `touch()` as it makes
    /// progress. Whatever `body` returns or throws first wins.
    func run<T: Sendable>(
        timeout: @escaping @Sendable (WatchdogPhase) -> any Error,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask { [self] in
                while true {
                    // The time is read under the same lock `touch()` takes,
                    // so a touch can't land between reading when the last one
                    // was and reading what time it is now.
                    //
                    // A touch only ever moves the deadline later, so waking at
                    // the old one and looking again is exact, with one
                    // exception: the first touch can bring it *earlier*, when
                    // `idle` is shorter than `first`. So until then, wake at
                    // least every `idle`, which is always before any deadline
                    // a touch made meanwhile.
                    let (wake, phase, expired) = state.withLock {
                        let now = clock.now
                        if $0.touched {
                            let deadline = $0.last.advanced(by: idle)
                            return (deadline, WatchdogPhase.idle, now >= deadline)
                        }
                        let deadline = $0.last.advanced(by: first)
                        return (min(deadline, now.advanced(by: idle)), WatchdogPhase.first, now >= deadline)
                    }
                    if expired { throw timeout(phase) }
                    try await clock.sleep(until: wake, tolerance: nil)
                }
            }
            defer { group.cancelAll() }
            // The watchdog child never returns normally, so the first result
            // is body's (or either child's error).
            guard let result = try await group.next(), let value = result else {
                throw CancellationError()
            }
            return value
        }
    }
}

extension Watchdog where C == ContinuousClock {
    convenience init(first: Duration, idle: Duration) {
        self.init(first: first, idle: idle, clock: ContinuousClock())
    }
}

/// Which allowance a `Watchdog` ran out of.
enum WatchdogPhase: Sendable {
    /// Nothing had arrived yet.
    case first
    /// Something arrived, then nothing more.
    case idle
}

/// `operation`, or nil if it hasn't finished within `limit` (it is then
/// cancelled). Dart's `Future.timeout` with an `onTimeout` that returns a
/// fallback.
func withTimeLimit<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T)
    async throws -> T?
{
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

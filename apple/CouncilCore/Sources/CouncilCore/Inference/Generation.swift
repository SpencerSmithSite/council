// The streaming half of the chat screen's `_sendMessage` / `_streamAnswer` /
// `_Generation` in lib/src/screens/chat_screen.dart, moved out of the screen
// so it can be tested without one. The cases of test/chat_streaming_test.dart
// are in GenerationTests.

import Synchronization

/// One answer being streamed, and the way to end it early.
///
/// ```swift
/// let generation = Generation(backend.generate(prompt: built.prompt, system: built.system))
/// self.generation = generation                 // so Stop can reach it
/// for await text in generation.updates {       // the answer so far, growing
///     bubble.text = text
/// }
/// let outcome = await generation.outcome
/// // outcome.answerText: the bubble's final text, or nil to remove it
/// // outcome.persistsAnswer: whether to store it (generated: true)
/// // outcome.notice: an app message to add after it (generated: false)
/// ```
///
/// Exists because of three failures the Flutter chat screen had, all
/// reachable with nothing more exotic than a flaky network:
///
/// - **Stop couldn't stop.** It set a flag the streaming loop read between
///   chunks, so a backend that accepted the request and went quiet left the
///   loop parked forever, with Stop greyed out and the composer disabled.
///   `stop()` here ends the generation at once, whatever the backend is doing,
///   and cancels the backend's stream (closing its connection).
/// - **An answer that failed before its first token left an empty bubble**,
///   carrying citations, above the error. The outcome says to remove the
///   bubble (`answerText` nil) and add the error as a notice.
/// - **Starting a new thread mid-answer wrote an error into the new one.**
///   Nothing here knows about threads: the screen keeps the conversation the
///   question was asked in and stores the outcome there, or calls `stop()`.
///
/// Beyond the Flutter screen, a stall limit: if nothing arrives for
/// `firstChunkTimeout` before the first piece, or `stallTimeout` between
/// pieces, the generation fails with a sentence saying so. That is the
/// backstop for backends with no time limits of their own (Ollama once
/// streaming, Foundation Models, MLX), so the composer can't stay locked even
/// if nobody presses Stop. The cloud backend's own one-minute limits fire
/// first. Reasoning that the backend's `ReasoningFilter` hides counts as
/// silence, which is why the first allowance is long.
///
/// Dropping the last reference to a `Generation` stops it, which is what
/// leaving the screen mid-answer should do.
public final class Generation: Sendable {
    /// How a generation ended.
    public enum Outcome: Sendable, Hashable {
        /// The stream finished. The text may be empty: a provider that returned
        /// nothing, or a model that emitted only reasoning.
        case completed(String)
        /// The reader pressed Stop. The text is what had arrived, maybe none.
        case stopped(String)
        /// The stream failed. `message` is the reader-facing notice
        /// (`ChatText.describe`); `partial` is what had arrived before.
        case failed(message: String, partial: String)
    }

    /// The default allowances. Five minutes for the first piece: a cold
    /// Ollama load of a large model, or a reasoning model thinking at length
    /// before its answer (Flutter's Ollama warm-up allows the same five
    /// minutes). Two minutes between pieces: once an answer is under way,
    /// every backend produces text many times a second.
    public static let defaultFirstChunkTimeout: Duration = .seconds(300)
    public static let defaultStallTimeout: Duration = .seconds(120)

    private struct State {
        var text = ""
        var stopRequested = false
    }

    /// Shared with the consuming task, which must not hold `self` (dropping
    /// the last reference is how a generation is abandoned).
    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    /// The answer so far, after each piece. Newest wins (a slow consumer sees
    /// the latest text, not every intermediate one), and it ends when the
    /// generation does. One consumer: iterate it once.
    public let updates: AsyncStream<String>

    private let shared: Shared
    private let task: Task<Outcome, Never>

    /// Starts consuming `chunks` at once.
    public convenience init(_ chunks: AsyncThrowingStream<String, any Error>,
                            firstChunkTimeout: Duration = Generation.defaultFirstChunkTimeout,
                            stallTimeout: Duration = Generation.defaultStallTimeout) {
        self.init(chunks, firstChunkTimeout: firstChunkTimeout, stallTimeout: stallTimeout, clock: ContinuousClock())
    }

    /// With the stall limit measured on `clock`, for tests.
    init<C: Clock & Sendable>(_ chunks: AsyncThrowingStream<String, any Error>, firstChunkTimeout: Duration,
                              stallTimeout: Duration, clock: C) where C.Duration == Duration {
        let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.updates = updates
        let shared = Shared()
        self.shared = shared
        let watchdog = Watchdog(first: firstChunkTimeout, idle: stallTimeout, clock: clock)
        task = Task {
            defer { continuation.finish() }
            do {
                try await watchdog.run(timeout: { phase in
                    switch phase {
                    case .first:
                        InferenceError("No answer arrived. The model may have stopped responding; ask again, "
                            + "or choose a different backend in Settings.")
                    case .idle:
                        InferenceError("The answer stopped arriving partway through. Ask again, or choose a "
                            + "different backend in Settings.")
                    }
                }) {
                    for try await chunk in chunks {
                        watchdog.touch()
                        // A piece that lands after Stop is not part of what
                        // the reader chose to keep.
                        let text: String? = shared.state.withLock {
                            guard !$0.stopRequested else { return nil }
                            $0.text += chunk
                            return $0.text
                        }
                        guard let text else { return }
                        continuation.yield(text)
                    }
                }
            } catch {
                return shared.state.withLock {
                    $0.stopRequested ? .stopped($0.text) : .failed(message: ChatText.describe(error), partial: $0.text)
                }
            }
            return shared.state.withLock { $0.stopRequested ? .stopped($0.text) : .completed($0.text) }
        }
    }

    deinit {
        task.cancel()
    }

    /// Ends the generation now, keeping what has arrived. The outcome is
    /// `.stopped`, however the backend responds to being cancelled, even if it
    /// had gone silent. Calling it again, or after the end, changes nothing.
    public func stop() {
        let changed = shared.state.withLock {
            guard !$0.stopRequested else { return false }
            $0.stopRequested = true
            return true
        }
        if changed { task.cancel() }
    }

    /// How it ended. Waits for the end.
    public var outcome: Outcome {
        get async { await task.value }
    }
}

public extension Generation.Outcome {
    /// What the answer bubble should finally say, or nil when the bubble
    /// should be removed. As the Flutter chat screen decides it:
    ///
    /// - finished: the answer, or `ChatText.emptyAnswer` if there was none (an
    ///   empty bubble reads as an answer still on its way);
    /// - stopped: what arrived, with `ChatText.stoppedSuffix`; nothing if
    ///   nothing arrived (nothing to keep, and nothing to tell the reader that
    ///   they don't already know);
    /// - failed: what arrived, if anything; the error goes in `notice`.
    var answerText: String? {
        switch self {
        case .completed(let text): text.isEmpty ? ChatText.emptyAnswer : text
        case .stopped(let text): text.isEmpty ? nil : text + ChatText.stoppedSuffix
        case .failed(_, let partial): partial.isEmpty ? nil : partial
        }
    }

    /// Whether to store `answerText` in the history (as a generated message
    /// carrying the prompt's citations), once, now that it is final.
    ///
    /// A stopped answer is stored: the reader stopped it because they had
    /// read enough, not because they wanted it thrown away. So is what a
    /// failed one managed to say before it failed, with the error stored
    /// after it as the notice: the partial text stays on screen, and a
    /// reopened thread has to show what the screen showed. (The Flutter
    /// screen once dropped it, so a reopened thread showed only the error;
    /// both apps now keep it.)
    var persistsAnswer: Bool {
        switch self {
        case .completed: true
        case .stopped(let text): !text.isEmpty
        case .failed(_, let partial): !partial.isEmpty
        }
    }

    /// A message the app adds after the answer (stored, not generated), when
    /// the generation failed.
    var notice: String? {
        if case .failed(let message, _) = self { message } else { nil }
    }
}

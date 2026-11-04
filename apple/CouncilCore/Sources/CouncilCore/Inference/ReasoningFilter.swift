// Port of lib/src/services/inference/reasoning_filter.dart. The cases in
// test/reasoning_filter_test.dart are ReasoningFilterTests.

/// Keeps a hybrid reasoning model's chain of thought out of the transcript.
///
/// Qwen 3 is a hybrid reasoning model: unless told otherwise it thinks first,
/// out loud, and only then answers. That thinking is wrapped in markers, and
/// nothing between the model and the transcript removes them on its own. In
/// the Flutter app they then became *invisible*: the Markdown renderer dropped
/// unknown HTML tags, so the reader saw several paragraphs of "First, looking
/// at source [1]…" with nothing to mark them as scratch work, and the chat
/// history stored them that way.
///
/// Two marker pairs, because the reasoning reaches the app by two routes and
/// only one of them is the model's own:
///
/// * `<think>…</think>`: what Qwen 3 itself emits, and what the reasoning
///   models an Ollama user is most likely to pull (`qwen3`, `deepseek-r1`)
///   emit too.
/// * `<|channel>thought…<channel|>`: what the Flutter app's LiteRT-LM SDK
///   rewrote reasoning into when the engine reported it on a separate channel.
///   The shape is Gemma's. The native app's MLX runtime is not known to produce
///   it, but which shape arrives is a property of the model bundle and the
///   engine build rather than of anything Council controls, so both are
///   handled here exactly as in Dart.
///
/// Written against chunks rather than the finished string because the answer
/// is streamed into the transcript as it arrives: waiting for the end to filter
/// would mean the reader watches the reasoning appear and then vanish. A marker
/// split across two chunks is the normal case rather than an edge one, so
/// anything that could still turn out to be the start of a marker is held back
/// until the next chunk settles it. Nothing else is held back.
///
/// Reasoning left unterminated when the stream ends is dropped, not emitted.
/// That happens when the model spends its whole token budget thinking and never
/// reaches an answer, and then there is no answer to show: printing the scratch
/// work instead is the bug this exists to stop.
///
/// The one case this only half-catches is a template that *prefills* the
/// opening marker, so the model's first token is the closer and the reasoning
/// ahead of it arrives unmarked. The stray closer is dropped (a raw marker has
/// no business in a stored transcript), but the prose before it has already
/// gone downstream, and recovering it would mean withholding the start of
/// every answer until a closer arrived or was ruled out: a visible stall on
/// every question, against a shape no Qwen 3 bundle has been seen to produce.
/// `ReasoningFilterTests` pins this so a change to it is deliberate.
///
/// Only the leading edge of the answer is trimmed. The model's first token
/// after `</think>` is usually a blank line, and a transcript that opens on one
/// looks broken; whitespace inside the answer is the model's formatting, and
/// trimming the trailing edge would mean holding every run of whitespace back
/// to see whether the answer continues, which stalls the stream to fix
/// something the reader can't see.
///
/// Strings are handled as UTF-16 code units, as Dart's are, with Dart's
/// `trimLeft` whitespace set. Every cut falls next to an ASCII marker
/// character or at a chunk's end, so no cut can split a surrogate pair.
public struct ReasoningFilter: Sendable {
    private struct Pair {
        let open: [UInt16]
        let close: [UInt16]
    }

    private static let pairs: [Pair] = [
        Pair(open: Array("<think>".utf16), close: Array("</think>".utf16)),
        // No trailing newline in the opener: the SDK wrote
        // `<|channel>thought\n`, and matching the marker without the separator
        // survives a chunk boundary landing between them.
        Pair(open: Array("<|channel>thought".utf16), close: Array("<channel|>".utf16)),
    ]

    /// Every marker string, for deciding how much of a buffer must be held
    /// back as a possible partial match.
    private static let markers: [[UInt16]] = pairs.flatMap { [$0.open, $0.close] }

    private var buffer: [UInt16] = []
    /// The pair whose reasoning block we are inside, if any.
    private var inside: Int?
    /// Whether any non-whitespace answer text has been emitted yet.
    private var emitted = false

    public init() {}

    /// Feeds one chunk and returns what can be emitted now, in order. Empty
    /// pieces are never returned.
    public mutating func feed(_ chunk: String) -> [String] {
        buffer.append(contentsOf: chunk.utf16)
        var out: [String] = []
        while true {
            if let pairIndex = inside {
                let close = Self.pairs[pairIndex].close
                if let end = Self.index(of: close, in: buffer) {
                    buffer.removeFirst(end + close.count)
                    inside = nil
                    continue
                }
                // Everything before a possible partial closer is reasoning;
                // discard it rather than growing a buffer the length of the
                // whole thought.
                let held = Self.partialSuffix(buffer, close)
                buffer.removeFirst(buffer.count - held)
                break
            }

            if let marker = Self.firstMarker(in: buffer) {
                if let before = lead(buffer[..<marker.at]) { out.append(before) }
                buffer.removeFirst(marker.at + marker.length)
                // A closing marker with nothing open is dropped where it
                // stands and nothing else changes (see the type's note).
                inside = marker.closing ? nil : marker.pair
                continue
            }
            let held = Self.markers.map { Self.partialSuffix(buffer, $0) }.max() ?? 0
            if let safe = lead(buffer[..<(buffer.count - held)]) { out.append(safe) }
            buffer.removeFirst(buffer.count - held)
            break
        }
        return out
    }

    /// Call when the stream ends: whatever was held back as a possible partial
    /// marker, unless it is inside an unterminated reasoning block.
    public mutating func finish() -> [String] {
        defer { buffer = [] }
        guard inside == nil, let tail = lead(buffer[...]) else { return [] }
        return [tail]
    }

    /// The answer stream with reasoning removed.
    ///
    /// Cancelling the consumer cancels the upstream iteration, so a backend's
    /// own `onTermination` still sees the cancellation and stops generating.
    /// An upstream error is passed through after whatever was emitted before
    /// it.
    public static func strip(_ chunks: AsyncThrowingStream<String, any Error>)
        -> AsyncThrowingStream<String, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var filter = ReasoningFilter()
                do {
                    for try await chunk in chunks {
                        for piece in filter.feed(chunk) { continuation.yield(piece) }
                    }
                    for piece in filter.finish() { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Leading-edge trim until the answer has started. Nil when nothing is
    /// left to emit.
    private mutating func lead(_ units: ArraySlice<UInt16>) -> String? {
        var slice = units
        if !emitted {
            while let first = slice.first, DartText.isTrimWhitespace(first) { slice = slice.dropFirst() }
            if !slice.isEmpty { emitted = true }
        }
        return slice.isEmpty ? nil : String(decoding: slice, as: UTF16.self)
    }

    /// The earliest marker in `buffer`, opening or closing.
    ///
    /// Earliest rather than first-pair-that-matches: all four are looked for
    /// at once, and taking whichever starts soonest keeps the text before it
    /// from being classified by the order the pairs happen to be declared in.
    private static func firstMarker(in buffer: [UInt16]) -> (at: Int, length: Int, closing: Bool, pair: Int)? {
        var best: (at: Int, length: Int, closing: Bool, pair: Int)?
        for (pairIndex, pair) in pairs.enumerated() {
            for (text, closing) in [(pair.open, false), (pair.close, true)] {
                if let at = index(of: text, in: buffer), best.map({ at < $0.at }) ?? true {
                    best = (at, text.count, closing, pairIndex)
                }
            }
        }
        return best
    }

    /// `String.indexOf`: the first position of `needle` in `haystack`.
    private static func index(of needle: [UInt16], in haystack: [UInt16]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0] && haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    /// How many code units at the end of `buffer` could still be the
    /// beginning of `marker`: what must be held back rather than emitted.
    /// Zero when the buffer can't be extended into the marker, so the common
    /// case costs nothing.
    private static func partialSuffix(_ buffer: [UInt16], _ marker: [UInt16]) -> Int {
        let most = min(buffer.count, marker.count - 1)
        var length = most
        while length > 0 {
            if buffer[(buffer.count - length)...].elementsEqual(marker[..<length]) { return length }
            length -= 1
        }
        return 0
    }
}

/// Keeps a hybrid reasoning model's chain of thought out of the transcript.
///
/// Qwen 3 is a hybrid reasoning model: unless told otherwise it thinks first,
/// out loud, and only then answers. That thinking is wrapped in markers, and
/// every layer that would normally remove them sits in a code path Council
/// does not use — `flutter_gemma` strips them inside `InferenceChat`, while
/// [LocalModelBackend] drives a bare session so that the RAG prompt is the
/// whole conversation. So the markers arrive intact and are then *invisible*:
/// `MarkdownBody` drops unknown HTML tags, which is why the reader saw several
/// paragraphs of "First, looking at source [1]…" with nothing to mark them as
/// scratch work.
///
/// Two marker pairs, because the reasoning reaches Dart by two different
/// routes and only one of them is the model's own:
///
/// * `<think>…</think>` — what Qwen 3 itself emits, passed through verbatim
///   when LiteRT-LM reports it as ordinary content.
/// * `<|channel>thought…<channel|>` — what `SdkTextExtractor` *rewrites*
///   reasoning into when LiteRT-LM reports it on a separate `channels.thought`
///   field. The shape is Gemma's, not Qwen's, and `flutter_gemma`'s own Qwen
///   filter only looks for `<think>`, so this pair leaks even on the path that
///   filters.
///
/// Both are handled because which one arrives is a property of the model
/// bundle and the engine build, not of anything Council controls.
class ReasoningFilter {
  const ReasoningFilter._();

  static const List<({String open, String close})> _pairs = [
    (open: '<think>', close: '</think>'),
    // No trailing newline in the opener: the extractor writes
    // `<|channel>thought\n`, and matching the marker without the separator
    // survives a chunk boundary landing between them.
    (open: '<|channel>thought', close: '<channel|>'),
  ];

  /// The answer, with any reasoning block removed.
  ///
  /// Written against chunks rather than the finished string because the answer
  /// is streamed into the transcript as it arrives — waiting for the end to
  /// filter would mean the reader watches the reasoning appear and then
  /// vanish. A marker split across two chunks is the normal case rather than
  /// an edge one, so anything that could still turn out to be the start of a
  /// marker is held back until the next chunk settles it.
  ///
  /// Reasoning left unterminated when the stream ends is dropped, not emitted.
  /// That happens when the model spends its whole token budget thinking and
  /// never reaches an answer, and in that case there is no answer to show —
  /// printing the scratch work instead is the bug this exists to stop.
  ///
  /// The one case this only half-catches is a template that *prefills* the
  /// opening marker, so the model's first emitted token is the closer and the
  /// reasoning ahead of it arrives already unmarked. `flutter_gemma` handles
  /// that shape for DeepSeek. Here the stray closer is dropped — a raw marker
  /// has no business in a stored transcript and removing it costs nothing —
  /// but the prose before it has already gone downstream, and recovering that
  /// would mean withholding the start of every answer until a closer either
  /// arrived or was ruled out. That is a visible stall on every question, paid
  /// against a shape no Qwen 3 bundle has been observed producing: verified on
  /// macOS against the real 0.6B weights, the model emits its own `<think>`.
  /// If a future bundle changes that, this is the assumption to revisit —
  /// `test/reasoning_filter_test.dart` pins the current behaviour so the
  /// change is deliberate.
  static Stream<String> strip(Stream<String> chunks) async* {
    var buffer = '';
    ({String open, String close})? inside;
    var emitted = false;

    // The model's first token after `</think>` is usually a blank line, and a
    // transcript that opens on one looks broken. Only the leading edge is
    // trimmed — whitespace inside the answer is the model's formatting, and
    // trimming the trailing edge would mean holding every run of whitespace
    // back to see whether the answer continues, which stalls the stream to fix
    // something the reader cannot see.
    String lead(String text) {
      if (emitted) return text;
      final trimmed = text.trimLeft();
      if (trimmed.isNotEmpty) emitted = true;
      return trimmed;
    }

    await for (final chunk in chunks) {
      buffer += chunk;
      while (true) {
        if (inside == null) {
          final marker = _firstMarker(buffer);
          if (marker != null) {
            final before = lead(buffer.substring(0, marker.at));
            if (before.isNotEmpty) yield before;
            buffer = buffer.substring(marker.at + marker.text.length);
            // A closing marker with nothing open is dropped where it stands
            // and nothing else changes. The reasoning that preceded it is
            // already gone downstream — see the note on [strip] — but the
            // marker itself has no business in a stored transcript, and
            // removing it costs nothing.
            inside = marker.closing ? null : marker.pair;
            continue;
          }
          final held = _markers
              .map((m) => _partialSuffix(buffer, m))
              .reduce((a, b) => a > b ? a : b);
          final safe = lead(buffer.substring(0, buffer.length - held));
          if (safe.isNotEmpty) yield safe;
          buffer = buffer.substring(buffer.length - held);
          break;
        }

        final end = buffer.indexOf(inside.close);
        if (end >= 0) {
          buffer = buffer.substring(end + inside.close.length);
          inside = null;
          continue;
        }
        // Everything before a possible partial closer is reasoning; discard it
        // rather than growing a buffer the length of the whole thought.
        buffer = buffer.substring(
          buffer.length - _partialSuffix(buffer, inside.close),
        );
        break;
      }
    }

    if (inside == null) {
      final tail = lead(buffer);
      if (tail.isNotEmpty) yield tail;
    }
  }

  /// Every marker string, for deciding how much of a buffer must be held back
  /// as a possible partial match.
  static final List<String> _markers = [
    for (final pair in _pairs) ...[pair.open, pair.close],
  ];

  /// The earliest marker in [buffer], opening or closing, or null if none is
  /// complete yet.
  ///
  /// Earliest rather than first-pair-that-matches: all four are looked for at
  /// once, and taking whichever starts soonest keeps the text before it from
  /// being classified by the order the pairs happen to be declared in.
  static ({
    int at,
    String text,
    bool closing,
    ({String open, String close}) pair,
  })? _firstMarker(String buffer) {
    ({
      int at,
      String text,
      bool closing,
      ({String open, String close}) pair,
    })? best;
    for (final pair in _pairs) {
      for (final (text, closing) in [(pair.open, false), (pair.close, true)]) {
        final at = buffer.indexOf(text);
        if (at >= 0 && (best == null || at < best.at)) {
          best = (at: at, text: text, closing: closing, pair: pair);
        }
      }
    }
    return best;
  }

  /// How many characters at the end of [buffer] could still be the beginning
  /// of [marker] — what must be held back rather than emitted.
  ///
  /// Zero when the buffer cannot be extended into the marker, so the common
  /// case costs nothing.
  static int _partialSuffix(String buffer, String marker) {
    final most = buffer.length < marker.length - 1
        ? buffer.length
        : marker.length - 1;
    for (var length = most; length > 0; length--) {
      if (buffer.endsWith(marker.substring(0, length))) return length;
    }
    return 0;
  }
}

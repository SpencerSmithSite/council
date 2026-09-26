/// Re-assembles a chunked character stream into whole lines.
///
/// Both streaming backends read a line-delimited protocol over HTTP — Ollama's
/// NDJSON and the cloud providers' Server-Sent Events — and a socket knows
/// nothing about either. A chunk boundary falls wherever the network put it,
/// which is routinely in the middle of a line, and the two halves are not
/// parseable as anything.
///
/// The bug this exists to prevent is quiet rather than loud. Splitting each
/// chunk on its own and skipping whatever fails to parse looks like it works —
/// most lines arrive whole — and loses a word here and there in a long answer,
/// with no error raised and nothing in the transcript to say a word is missing.
/// The reader gets a fluent sentence with a hole in it.
///
/// A trailing fragment with no closing newline is emitted when the stream ends,
/// so a server that does not terminate its last line does not lose it either.
Stream<String> wholeLines(Stream<String> chunks) async* {
  var buffer = '';
  await for (final chunk in chunks) {
    buffer += chunk;
    while (true) {
      final newline = buffer.indexOf('\n');
      if (newline < 0) break;
      yield buffer.substring(0, newline);
      buffer = buffer.substring(newline + 1);
    }
  }
  if (buffer.isNotEmpty) yield buffer;
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:council/src/services/ollama_service.dart';
import 'package:council/src/util/stream_lines.dart';

/// A client that returns a streamed response whose chunk boundaries the test
/// chooses. Where the boundaries fall is the entire subject here, so a fake that
/// picked them itself would be testing nothing.
class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.chunks);

  final List<String> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = Stream.fromIterable(chunks.map(utf8.encode));
    return http.StreamedResponse(bytes, 200);
  }
}

/// One NDJSON object per line, as Ollama sends them.
String _token(String text) => '${jsonEncode({
      'response': text,
      'done': false,
    })}\n';

void main() {
  group('wholeLines', () {
    test('a line split across two chunks arrives in one piece', () async {
      final lines = await wholeLines(Stream.fromIterable(['he', 'llo\n']))
          .toList();
      expect(lines, ['hello']);
    });

    test('several lines in a single chunk all come through', () async {
      final lines =
          await wholeLines(Stream.fromIterable(['a\nb\nc\n'])).toList();
      expect(lines, ['a', 'b', 'c']);
    });

    test('a chunk boundary on the newline itself is not a lost line', () async {
      final lines =
          await wholeLines(Stream.fromIterable(['a\n', '\nb\n'])).toList();
      expect(lines, ['a', '', 'b']);
    });

    test('a trailing fragment with no closing newline is still emitted',
        () async {
      // A server that ends its last line without terminating it should not
      // cost the reader that line.
      final lines =
          await wholeLines(Stream.fromIterable(['a\nb'])).toList();
      expect(lines, ['a', 'b']);
    });

    test('an empty stream yields nothing rather than one empty line', () async {
      expect(await wholeLines(const Stream<String>.empty()).toList(), isEmpty);
    });

    test('a single byte at a time still reassembles', () async {
      const text = 'first line\nsecond line\n';
      final lines =
          await wholeLines(Stream.fromIterable(text.split(''))).toList();
      expect(lines, ['first line', 'second line']);
    });
  });

  group('Ollama streaming does not drop a word at a chunk boundary', () {
    test('a token whose JSON is split in half is not lost', () async {
      // The failure this is here for: the two halves of one object each fail to
      // parse, both are skipped as malformed, and the word vanishes out of the
      // middle of the answer with no error anywhere.
      final whole = _token('justification');
      final cut = whole.length ~/ 2;
      final service = OllamaService(
        clientFactory: () => _ChunkedClient([
          _token('On '),
          whole.substring(0, cut),
          whole.substring(cut),
          '${jsonEncode({'response': ' alone', 'done': true})}\n',
        ]),
      );

      final pieces =
          await service.generateStream(prompt: 'anything').toList();

      expect(pieces.join(), 'On justification alone');
    });

    test('a stream arriving one character at a time is intact', () async {
      final payload = [
        _token('Grace'),
        _token(' and'),
        _token(' peace'),
        '${jsonEncode({'response': '.', 'done': true})}\n',
      ].join();
      final service = OllamaService(
        clientFactory: () => _ChunkedClient(payload.split('')),
      );

      final pieces =
          await service.generateStream(prompt: 'anything').toList();

      expect(pieces.join(), 'Grace and peace.');
    });

    test('a genuinely malformed line is still skipped', () async {
      // The old catch swallowed half-lines along with real garbage. It still
      // has to swallow the real garbage.
      final service = OllamaService(
        clientFactory: () => _ChunkedClient([
          'this is not json at all\n',
          _token('Amen'),
          '${jsonEncode({'response': '.', 'done': true})}\n',
        ]),
      );

      expect(
        (await service.generateStream(prompt: 'anything').toList()).join(),
        'Amen.',
      );
    });

    test('done stops the stream even with more lines behind it', () async {
      final service = OllamaService(
        clientFactory: () => _ChunkedClient([
          _token('Enough'),
          '${jsonEncode({'response': '.', 'done': true})}\n',
          _token(' and then some'),
        ]),
      );

      expect(
        (await service.generateStream(prompt: 'anything').toList()).join(),
        'Enough.',
      );
    });
  });
}

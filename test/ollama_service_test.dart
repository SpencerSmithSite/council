import 'package:flutter_test/flutter_test.dart';
import 'package:council/src/services/ollama_service.dart';

void main() {
  group('ContextPassage.contextContent', () {
    test('leaves a short passage untouched', () {
      final passage = ContextPassage(
        source: 'The Confessions',
        content: 'Our heart is restless until it rests in you.',
      );

      expect(passage.contextContent, passage.content);
    });

    test('truncates a passage that would swamp the context window', () {
      // The longest single unit in the bundled database is ~83 KB.
      final passage = ContextPassage(
        source: 'Summa Theologica',
        content: List.filled(20000, 'word').join(' '),
      );

      expect(
        passage.contextContent.length,
        lessThan(ContextPassage.maxContextChars + 40),
      );
      expect(passage.contextContent, endsWith('[passage truncated]'));
    });

    test('cuts at a word boundary rather than mid-word', () {
      final passage = ContextPassage(
        source: 'Institutes',
        content: List.filled(2000, 'sanctification').join(' '),
      );

      final body = passage.contextContent.split('…').first;
      expect(body.endsWith('sanctification'), isTrue);
    });

    test('still truncates content with no whitespace to cut on', () {
      final passage = ContextPassage(
        source: 'Malformed',
        content: 'x' * 5000,
      );

      expect(
        passage.contextContent.length,
        lessThan(ContextPassage.maxContextChars + 40),
      );
    });
  });
}

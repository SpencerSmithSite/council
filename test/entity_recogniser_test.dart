import 'package:flutter_test/flutter_test.dart';
import 'package:theology_app/src/services/search/entity_recogniser.dart';

/// Fixtures mirroring the shape of the real corpus: an author with many works,
/// multi-word confession titles, and titles whose words are also ordinary
/// theological vocabulary.
EntityRecogniser _recogniser() => EntityRecogniser.build(
      sources: [
        for (var i = 1; i <= 6; i++)
          {'id': i, 'title': 'On the Trinity, Book $i', 'author': 'Augustine of Hippo'},
        {'id': 10, 'title': 'Council of Trent', 'author': null},
        {'id': 11, 'title': 'The Heidelberg Catechism', 'author': null},
        {'id': 12, 'title': 'The Belgic Confession', 'author': null},
        {'id': 13, 'title': 'Homilies on Matthew', 'author': 'John Chrysostom'},
        {'id': 14, 'title': 'Homilies on Acts', 'author': 'John Chrysostom'},
        // A second John, so "John" alone genuinely disambiguates nothing —
        // the real corpus has Chrysostom, Damascus and Cassian.
        {'id': 15, 'title': 'Exposition of the Orthodox Faith', 'author': 'John of Damascus'},
        // Titles built from ordinary vocabulary — the false-positive traps.
        {'id': 20, 'title': 'Who is the Rich Man That Shall Be Saved?', 'author': null},
        {'id': 21, 'title': 'Apocalypse of the Virgin', 'author': null},
        {'id': 22, 'title': 'Twelve Topics on the Faith', 'author': null},
      ],
      traditions: [
        {'id': 1, 'name': 'Catholic'},
        {'id': 2, 'name': 'Lutheran'},
        {'id': 3, 'name': 'Reformed'},
        {'id': 4, 'name': 'Early Church'},
      ],
    );

void main() {
  late EntityRecogniser recogniser;

  setUp(() => recogniser = _recogniser());

  group('traditions', () {
    test('recognises a tradition named adjectivally', () {
      // Questions say "what do Lutherans believe", not "the Lutheran tradition".
      final result = recogniser.recognise(
        'What are the differences between Catholic and Lutheran beliefs?',
      );
      expect(result.traditionIds, {1, 2});
    });

    test('matches metadata, not body vocabulary', () {
      // "Catholic" in a question means the modern communion; matching the
      // tradition row cannot be confused by Augustine's use of the word for
      // the universal church.
      expect(recogniser.recognise('Catholic teaching').traditionIds, {1});
    });
  });

  group('authors', () {
    test('scopes to everything an author wrote', () {
      final result = recogniser.recognise('What did Augustine say about grace?');
      expect(result.sourceIds, {1, 2, 3, 4, 5, 6});
      expect(result.labels, contains('Augustine of Hippo'));
    });

    test('resolves an author by a distinctive surname alone', () {
      final result = recogniser.recognise('What does Chrysostom say about wealth?');
      expect(result.sourceIds, {13, 14});
    });

    test('ignores a forename shared between authors', () {
      // "John" alone identifies nobody, and must not scope.
      expect(recogniser.recognise('what did John teach').isEmpty, isTrue);
    });
  });

  group('works', () {
    test('recognises a work named in full', () {
      final result = recogniser.recognise('What topics were covered at the Council of Trent?');
      expect(result.sourceIds, contains(10));
    });

    test('recognises a long title from a distinctive token plus one more', () {
      // Renaming "Council of Trent" to its full form broke scoping: two of
      // four title tokens fell under the fraction threshold. "Trent" is
      // distinctive, so two tokens including it is enough.
      final long = EntityRecogniser.build(
        sources: [
          {'id': 30, 'title': 'The Canons and Decrees of the Council of Trent',
           'author': null},
          {'id': 31, 'title': 'Twelve Topics on the Faith', 'author': null},
        ],
        traditions: const [],
      );

      expect(
        long.recognise('What did the Council of Trent decree about justification?')
            .sourceIds,
        contains(30),
      );
      // Still must not fire on one ordinary token.
      expect(long.recognise('What topics matter most?').sourceIds, isEmpty);
    });

    test('recognises a multi-word confession title', () {
      expect(
        recogniser.recognise('the Heidelberg Catechism on the sacraments').sourceIds,
        contains(11),
      );
      expect(
        recogniser.recognise('what does the Belgic Confession say').sourceIds,
        contains(12),
      );
    });
  });

  group('false positives', () {
    // These are the cases that made a rare-token rule untenable: each word is
    // rare among titles while being ordinary theological vocabulary.
    test('a topical question does not scope to a similarly-worded title', () {
      expect(recogniser.recognise('How is a person saved?').isEmpty, isTrue);
      expect(recogniser.recognise('What topics matter most?').isEmpty, isTrue);
    });

    test('a question about the Virgin Mary is not a question about one work', () {
      final result = recogniser.recognise('What did Aquinas say about the Virgin Mary?');
      expect(result.sourceIds, isNot(contains(21)));
    });

    test('naming many works means naming a topic, not a work', () {
      // "Trinity" appears in six titles; the question is about the doctrine.
      final result = recogniser.recognise('Explain the doctrine of the Trinity');
      expect(result.sourceIds, isEmpty);
    });

    test('an ordinary question scopes to nothing', () {
      expect(recogniser.recognise('Is the Son equal to the Father?').isEmpty, isTrue);
      expect(recogniser.recognise('').isEmpty, isTrue);
    });
  });

  test('reports what it understood, for showing the user', () {
    // Silently narrowing a search is worse than saying what was narrowed to.
    final result = recogniser.recognise('What did Augustine say about the Trinity?');
    expect(result.labels, isNotEmpty);
    expect(result.isNotEmpty, isTrue);
  });
}

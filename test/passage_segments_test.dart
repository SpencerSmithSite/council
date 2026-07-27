import 'package:council/src/reader/passage_segments.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a reader can tap, and what comes back out when they do.
///
/// Pure, so it lives in the unit suite. The corpus samples below are copied
/// from the shipped database rather than invented: Scripture is stored one
/// numbered verse per line, confessional articles as a single dense paragraph,
/// and both have to segment sensibly without the code knowing which is which.
void main() {
  group('verses', () {
    const genesis = '1. In the beginning God created the heaven and the earth.\n'
        '2. And the earth was without form, and void; and darkness was upon '
        'the face of the deep.\n'
        '3. And God said, Let there be light: and there was light.\n';

    test('one segment per numbered line', () {
      final passage = segmentPassage(genesis);
      expect(passage.kind, SegmentKind.verse);
      expect(passage.segments, hasLength(3));
      expect(passage.segments.map((s) => s.number), [1, 2, 3]);
    });

    test('the number is not part of the quoted text', () {
      final passage = segmentPassage(genesis);
      expect(passage.segments.first.text, startsWith('In the beginning'));
      expect(passage.segments.first.text, isNot(contains('1.')));
    });

    test('offsets cover the number, so a highlight includes it', () {
      final passage = segmentPassage(genesis);
      final first = passage.segments.first;
      expect(genesis.substring(first.start, first.end), startsWith('1.'));
      expect(genesis.substring(first.start, first.end), endsWith('earth.'));
    });

    test('a single numbered line is not read as verses', () {
      // "1. " opens plenty of prose. One marker is not a numbered text.
      final passage = segmentPassage(
          '1. The first point, at some length, and then nothing further.');
      expect(passage.kind, isNot(SegmentKind.verse));
    });

    test('text before the first verse still gets a segment', () {
      final passage = segmentPassage(
          'The First Book of Moses\n1. In the beginning.\n2. And the earth.');
      expect(passage.segments, hasLength(3));
      expect(passage.segments.first.number, isNull);
      expect(passage.segments.first.text, 'The First Book of Moses');
    });
  });

  group('prose', () {
    test('paragraphs separated by blank lines', () {
      final passage = segmentPassage('First paragraph.\n\nSecond paragraph.');
      expect(passage.kind, SegmentKind.paragraph);
      expect(passage.segments.map((s) => s.text),
          ['First paragraph.', 'Second paragraph.']);
    });

    test('a confessional article stays whole', () {
      const article =
          'We believe and confess that the canonical Scriptures of the holy '
          'prophets and apostles are the true Word of God, and that they have '
          'sufficient authority in themselves and apart from the authority of '
          'men.';
      final passage = segmentPassage(article);
      expect(passage.segments, hasLength(1));
      expect(passage.segments.single.text, article);
    });

    test('an over-long paragraph is split at sentence boundaries', () {
      final long = List.filled(
              12, 'This is a sentence of a reasonable and unremarkable length.')
          .join(' ');
      expect(long.length, greaterThan(700));

      final passage = segmentPassage(long);
      expect(passage.kind, SegmentKind.sentence);
      expect(passage.segments, hasLength(12));
      expect(passage.segments.every((s) => s.text.endsWith('length.')), isTrue);
    });

    test('offsets always index back into the original text', () {
      const content = 'One paragraph here.\n\nAnother one, over here.';
      for (final segment in segmentPassage(content).segments) {
        expect(content.substring(segment.start, segment.end), segment.text);
      }
    });

    test('an empty passage yields nothing rather than one empty segment', () {
      expect(segmentPassage('   \n\n  ').isEmpty, isTrue);
    });
  });

  group('references', () {
    List<PassageSegment> verses(List<int> numbers) => [
          for (var i = 0; i < numbers.length; i++)
            PassageSegment(
                index: i, start: 0, end: 1, text: 'x', number: numbers[i]),
        ];

    test('a run collapses to a range', () {
      expect(referenceFor('Genesis 1', verses([4, 5, 6])), 'Genesis 1:4–6');
    });

    test('two adjacent verses are listed, not ranged', () {
      // "4–5" saves no characters over "4, 5" and reads worse.
      expect(referenceFor('Genesis 1', verses([4, 5])), 'Genesis 1:4, 5');
    });

    test('gaps are preserved', () {
      expect(referenceFor('Judges 6', verses([4, 5, 9])), 'Judges 6:4, 5, 9');
    });

    test('prose falls back to the section title', () {
      expect(referenceFor('Of the Holy Scripture', const []),
          'Of the Holy Scripture');
    });
  });

  group('quoting', () {
    test('verses run together as prose', () {
      final passage = segmentPassage('1. First verse.\n2. Second verse.');
      expect(quoteFor(passage, [0, 1]), 'First verse. Second verse.');
    });

    test('a gap in the selection is marked, not closed', () {
      // Quoting verses 1 and 3 as though consecutive misrepresents the text.
      final passage =
          segmentPassage('1. First verse.\n2. Second verse.\n3. Third verse.');
      expect(quoteFor(passage, [0, 2]), 'First verse. … Third verse.');
    });

    test('paragraphs keep their break', () {
      final passage = segmentPassage('First para.\n\nSecond para.');
      expect(quoteFor(passage, [0, 1]), 'First para.\n\nSecond para.');
    });

    test('selection order does not matter', () {
      final passage = segmentPassage('1. First verse.\n2. Second verse.');
      expect(quoteFor(passage, [1, 0]), quoteFor(passage, [0, 1]));
    });
  });
}

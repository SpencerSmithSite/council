import 'package:council/src/reader/passage_segments.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a reader can tap, and what comes back out when they do.
///
/// Pure, so it lives in the unit suite. The corpus samples below are copied
/// from the shipped database rather than invented: Scripture is stored one
/// numbered verse per line, confessional articles as a single dense paragraph,
/// and both have to segment sensibly without the code knowing which is which.
void main() {
  _numberedProseTests();
  _referenceCoversQuoteTests();
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

/// Numbered prose is not numbered text.
///
/// _segmentVerses believed any two lines starting `1. ` / `2. `, and 23,143 of
/// the corpus's 99,651 non-scripture units matched — a sermon enumerating two
/// points, a commentary listing three objections. Everything downstream believed
/// it too: the citation gained a verse number that does not exist, the toolbar
/// counted verses, and because the verse path returns early the paragraph split
/// never ran, so the prose above the first number stayed one untappable block.
///
/// What separates them is how much text a number governs. Measured on the
/// shipped corpus: for the genuinely numbered types the median run is 130–344
/// characters (99th percentile of those medians, 213); for the prose types the
/// 25th percentile is 651 and the median 1,319.
void _numberedProseTests() {
  /// A sermon that makes two numbered points, of the length they actually run to.
  String sermonWithTwoPoints() {
    final preamble = List.filled(18, 'The question before us is a plain one, '
        'and it will not be answered by evasion.').join(' ');
    final first = List.filled(20, 'Consider first that holiness is not '
        'optional for those who profess it.').join(' ');
    final second = List.filled(16, 'Consider secondly the cost of neglecting '
        'it, which is greater than men suppose.').join(' ');
    return '$preamble\n\n1. $first\n\n2. $second\n';
  }

  group('a numbered list inside prose is not verses', () {
    test('two long numbered points do not make a verse passage', () {
      final passage = segmentPassage(sermonWithTwoPoints());
      expect(passage.kind, isNot(SegmentKind.verse));
    });

    test('no fabricated verse number reaches the citation', () {
      final passage = segmentPassage(sermonWithTwoPoints());
      final reference = referenceFor('XV. Lovest Thou Me?', passage.segments);
      // The old output was "XV. Lovest Thou Me?:1, 2" — a verse reference for a
      // sermon that has no verses.
      expect(reference, 'XV. Lovest Thou Me?');
      expect(reference, isNot(contains(':')));
    });

    test('the prose above the first number becomes tappable', () {
      // The verse path returns before _segmentProse, so the paragraph-splitting
      // threshold never ran and a 2,567-character preamble was one tap target.
      final passage = segmentPassage(sermonWithTwoPoints());
      expect(passage.segments.length, greaterThan(3));
      for (final segment in passage.segments) {
        expect(segment.text.length, lessThan(1400),
            reason: 'no segment should be a page of prose');
      }
    });
  });

  group('genuinely numbered text still segments as verses', () {
    test('a short psalm of two verses', () {
      // Psalm 117 is two verses long, so a minimum marker count would have been
      // the wrong rule.
      const psalm = '1. O praise the LORD, all ye nations: praise him, all ye '
          'people.\n'
          '2. For his merciful kindness is great toward us: and the truth of '
          'the LORD endureth for ever. Praise ye the LORD.\n';
      final passage = segmentPassage(psalm);
      expect(passage.kind, SegmentKind.verse);
      expect(passage.segments.map((s) => s.number), [1, 2]);
    });

    test('confessional articles, which run longer than verses', () {
      // The median numbered run in the corpus's Confession units is 224
      // characters; these are near that.
      const article = 'God hath endued the will of man with that natural '
          'liberty, that it is neither forced, nor by any absolute necessity '
          'of nature determined to good or evil. Man, in his state of '
          'innocency, had freedom and power to will and to do that which is '
          'good and well-pleasing to God.';
      const text = '1. $article\n2. $article\n3. $article\n';
      final passage = segmentPassage(text);
      expect(passage.kind, SegmentKind.verse);
      expect(passage.segments.map((s) => s.number), [1, 2, 3]);
    });

    test('a chapter heading above verse 1 keeps its own segment', () {
      const withHeading = 'THE FIRST BOOK OF MOSES\n'
          '1. In the beginning God created the heaven and the earth.\n'
          '2. And the earth was without form, and void.\n';
      final passage = segmentPassage(withHeading);
      expect(passage.kind, SegmentKind.verse);
      expect(passage.segments.first.number, isNull);
      expect(passage.segments.first.text, 'THE FIRST BOOK OF MOSES');
    });
  });
}

/// A reference must cover everything the quote beside it contains.
void _referenceCoversQuoteTests() {
  const withHeading = 'THE FIRST BOOK OF MOSES\n'
      '1. In the beginning God created the heaven and the earth.\n'
      '2. And the earth was without form, and void.\n';

  group('a reference never claims less than the quote holds', () {
    test('heading plus verse 1 is cited by title, not by verse', () {
      final passage = segmentPassage(withHeading);
      final selected = [passage.segments[0], passage.segments[1]];

      final quote = quoteFor(passage, [0, 1]);
      final reference = referenceFor('Genesis 1', selected);

      // The pair that used to go to the clipboard, the share sheet, a saved note
      // and the model was: "THE FIRST BOOK OF MOSES In the beginning…" under
      // "Genesis 1:1" — a reference covering one verse of a quote that also
      // contained the heading.
      expect(quote, contains('THE FIRST BOOK OF MOSES'));
      expect(reference, 'Genesis 1');
      expect(reference, isNot(contains(':1')));
    });

    test('verses on their own are still cited precisely', () {
      final passage = segmentPassage(withHeading);
      expect(referenceFor('Genesis 1', [passage.segments[1]]), 'Genesis 1:1');
      expect(
          referenceFor('Genesis 1',
              [passage.segments[1], passage.segments[2]]),
          'Genesis 1:1, 2');
    });

    test('the heading on its own is cited by title', () {
      final passage = segmentPassage(withHeading);
      expect(referenceFor('Genesis 1', [passage.segments[0]]), 'Genesis 1');
    });

    test('with no title there is nothing honest to claim', () {
      final passage = segmentPassage(withHeading);
      expect(referenceFor(null, [passage.segments[0], passage.segments[1]]), '');
    });
  });
}

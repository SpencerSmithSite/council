import 'package:flutter_test/flutter_test.dart';
import 'package:council/src/services/search/wordpiece_tokenizer.dart';

/// The Dart tokenizer must produce byte-identical token ids to the Python
/// tokenizer used at build time. If it does not, query vectors land in a
/// slightly different place than document vectors and semantic search degrades
/// silently — no error, just worse results. These expectations are the actual
/// output of `tokenizers.Tokenizer.from_file(tokenizer.json)`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WordPieceTokenizer tokenizer;

  setUpAll(() async {
    tokenizer = await WordPieceTokenizer.load();
  });

  const cases = <String, List<int>>{
    'How is a person saved?': [101, 2129, 2003, 1037, 2711, 5552, 1029, 102],
    'justification by faith alone': [101, 19777, 2011, 4752, 2894, 102],
    'What did Augustine say about grace?': [
      101, 2054, 2106, 14060, 2360, 2055, 4519, 1029, 102,
    ],
    // Punctuation must be peeled into its own tokens: "A.D." -> a . d .
    'the Nicene Creed, A.D. 325': [
      101, 1996, 3835, 2638, 16438, 1010, 1037, 1012, 1040, 1012, 19652, 102,
    ],
    // Apostrophe splits, and long words fall back to subword pieces.
    "Chrysostom's homilies on Matthew": [
      101, 10381, 24769, 14122, 5358, 1005, 1055, 7570, 4328, 11983, 2006,
      5487, 102,
    ],
    'Nicaea and the homoousion': [
      101, 27969, 21996, 1998, 1996, 24004, 3560, 3258, 102,
    ],
    'eschatology': [101, 9686, 7507, 23479, 102],
    'transubstantiation': [101, 9099, 12083, 12693, 10711, 3508, 102],

    // Greek and accented Latin, which the hand-written thirty-entry folding
    // table did not reach. A word with one unfoldable character is not partly
    // matched — _wordPiece emits a single [UNK] for the whole word — and the
    // vocabulary holds all 24 bare Greek letters and none of the accented
    // forms, so every one of these encoded to [UNK] and the query vector was
    // built from nothing. Ids from tokenizers 0.23.2 against the shipped
    // tokenizer.json, same as everything above.
    'ὁμοούσιος': [101, 1169, 29728, 29730, 26789, 29733, 18199, 15297, 102],
    'Νίκαια': [101, 1167, 18199, 29726, 14608, 27432, 102],
    'Grégoire de Nazianze': [101, 6754, 26250, 2139, 6394, 2319, 4371, 102],
    'Küng': [101, 18577, 102],
    'façade': [101, 8508, 102],
    'the ὁμοούσιος of the Son': [
      101, 1996, 1169, 29728, 29730, 26789, 29733, 18199, 15297, 1997, 1996,
      2365, 102,
    ],
  };

  test('matches the Python tokenizer exactly', () {
    cases.forEach((text, expected) {
      expect(tokenizer.encode(text), expected, reason: 'for "$text"');
    });
  });

  test('a decomposed spelling encodes the same as a precomposed one', () {
    // macOS hands over NFD on paste, so "Nicée" typed on a Mac can arrive as
    // `e` + U+0301. HuggingFace decomposes everything anyway and so cannot tell
    // the two apart; this side kept the combining mark, which made the word
    // unknown. Two spellings Unicode calls equal encoded to entirely different
    // vectors, and one of them to nothing.
    const precomposed = 'Gr\u00E9goire de Nazianze';
    const decomposed = 'Gre\u0301goire de Nazianze';

    expect(tokenizer.encode(decomposed), tokenizer.encode(precomposed));
    expect(tokenizer.encode(decomposed),
        [101, 6754, 26250, 2139, 6394, 2319, 4371, 102]);
  });

  test('an accented word is never reduced to the unknown token', () {
    // The shape of the old failure, stated directly: the whole word replaced by
    // [UNK], id 100. "Küng" is a single vocabulary word once folded ("kung"), so
    // the test is about [UNK] and not about how many pieces a word makes.
    for (final word in [
      'ὁμοούσιος',
      'Νίκαια',
      'Grégoire',
      'Küng',
      'façade',
      'Ἰησοῦς',
      'θεολογία',
    ]) {
      expect(tokenizer.encode(word), isNot(contains(100)),
          reason: '"$word" encoded to [UNK]');
    }
  });

  test('wraps every sequence in [CLS] and [SEP]', () {
    final ids = tokenizer.encode('grace');
    expect(ids.first, 101);
    expect(ids.last, 102);
  });

  test('truncates to the model input length', () {
    final ids = tokenizer.encode(List.filled(500, 'theology').join(' '));
    expect(ids.length, lessThanOrEqualTo(WordPieceTokenizer.maxTokens));
    expect(ids.last, 102, reason: '[SEP] must survive truncation');
  });

  test('handles empty and punctuation-only input', () {
    expect(tokenizer.encode(''), [101, 102]);
    expect(tokenizer.encode('???').length, greaterThan(2));
  });
}

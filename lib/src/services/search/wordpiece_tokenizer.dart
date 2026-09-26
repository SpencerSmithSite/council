import 'package:flutter/services.dart';

/// BERT WordPiece tokenizer, matching the `bert-base-uncased` scheme the
/// bundled embedding model was trained with.
///
/// The ONNX runtime executes the model but does not tokenize, and there is no
/// maintained Dart port of HuggingFace tokenizers. This implements the same
/// pipeline the Python side uses at build time — normalize, split, then greedy
/// longest-match against the vocabulary. Query and document vectors must come
/// from identical preprocessing or the two are not comparable.
class WordPieceTokenizer {
  static const String _unknown = '[UNK]';
  static const String _classify = '[CLS]';
  static const String _separate = '[SEP]';
  static const String _continuation = '##';

  /// Matches the build-time truncation length.
  static const int maxTokens = 256;

  final Map<String, int> _vocab;

  WordPieceTokenizer._(this._vocab);

  static Future<WordPieceTokenizer> load([
    String asset = 'assets/model/vocab.txt',
  ]) async {
    final raw = await rootBundle.loadString(asset);
    final vocab = <String, int>{};
    final lines = raw.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final token = lines[i].trimRight();
      if (token.isNotEmpty) vocab[token] = i;
    }
    return WordPieceTokenizer._(vocab);
  }

  /// BertNormalizer: lowercase, strip control characters, collapse whitespace.
  /// `strip_accents` is null in the model's config, which for a lowercasing
  /// BertNormalizer means accents ARE stripped — so we strip them here too.
  String _normalize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      // Skip control characters and the replacement character.
      if (rune == 0 || rune == 0xFFFD) continue;
      if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) continue;
      buffer.writeCharCode(rune);
    }
    return _stripAccents(buffer.toString());
  }

  /// Fold a character to what the build-time tokenizer leaves of it.
  ///
  /// `assets/model/tokenizer.json` declares
  /// `BertNormalizer(strip_accents: null, lowercase: true)`, and in that
  /// configuration strip_accents follows lowercase — so the Python side that
  /// embedded the corpus decomposed every character to NFD and dropped every
  /// combining mark. This side had a hand-written table of thirty precomposed
  /// Latin-1 letters, which is a different function, and the file's own comment
  /// insists query and document vectors must come from identical preprocessing.
  ///
  /// What the difference cost: a word containing any character this table missed
  /// was not partially matched, it was discarded whole, because [_wordPiece]
  /// emits a single `[UNK]` when no prefix of the remainder is in the
  /// vocabulary. The vocabulary holds all 24 bare Greek letters and none of the
  /// accented forms, so "ὁμοούσιος" encoded to exactly one token — `[UNK]` —
  /// and the query vector for the most load-bearing word in the Arian
  /// controversy was built from nothing. Folded, it is
  /// `ο ##μ ##ο ##ου ##σ ##ι ##ος`, which is what the documents were embedded
  /// as. "Grégoire" was `[UNK]` too, and is now `greg ##oire`.
  ///
  /// Generated from the shipped corpus rather than written by hand: every
  /// non-ASCII character in the 108,623 bundled units, and its lowercase form,
  /// folded through Python's unicodedata the same way the build does. 131
  /// entries, of which 95 were missing and account for 4,668 occurrences —
  /// 87 of them Greek.
  static const Map<String, String> _folding = {
    '\u00C1': 'A', '\u00C2': 'A', '\u00C3': 'A', '\u00C9': 'E',
    '\u00CA': 'E', '\u00CC': 'I', '\u00CE': 'I', '\u00D1': 'N',
    '\u00DC': 'U', '\u00E0': 'a', '\u00E1': 'a', '\u00E2': 'a',
    '\u00E3': 'a', '\u00E4': 'a', '\u00E7': 'c', '\u00E8': 'e',
    '\u00E9': 'e', '\u00EA': 'e', '\u00EB': 'e', '\u00EC': 'i',
    '\u00ED': 'i', '\u00EE': 'i', '\u00EF': 'i', '\u00F1': 'n',
    '\u00F2': 'o', '\u00F3': 'o', '\u00F4': 'o', '\u00F6': 'o',
    '\u00F9': 'u', '\u00FA': 'u', '\u00FB': 'u', '\u00FC': 'u',
    '\u0115': 'e', '\u011B': 'e', '\u014D': 'o', '\u014F': 'o',
    '\u0160': 'S', '\u0161': 's', '\u017E': 'z', '\u0387': '\u00B7',
    '\u03AC': '\u03B1', '\u03AD': '\u03B5', '\u03AE': '\u03B7',
    '\u03AF': '\u03B9', '\u03CA': '\u03B9', '\u03CC': '\u03BF',
    '\u03CD': '\u03C5', '\u1F00': '\u03B1', '\u1F01': '\u03B1',
    '\u1F02': '\u03B1', '\u1F04': '\u03B1', '\u1F05': '\u03B1',
    '\u1F0C': '\u0391', '\u1F0D': '\u0391', '\u1F10': '\u03B5',
    '\u1F11': '\u03B5', '\u1F12': '\u03B5', '\u1F13': '\u03B5',
    '\u1F14': '\u03B5', '\u1F15': '\u03B5', '\u1F18': '\u0395',
    '\u1F20': '\u03B7', '\u1F21': '\u03B7', '\u1F22': '\u03B7',
    '\u1F24': '\u03B7', '\u1F25': '\u03B7', '\u1F26': '\u03B7',
    '\u1F29': '\u0397', '\u1F30': '\u03B9', '\u1F31': '\u03B9',
    '\u1F32': '\u03B9', '\u1F34': '\u03B9', '\u1F35': '\u03B9',
    '\u1F36': '\u03B9', '\u1F37': '\u03B9', '\u1F40': '\u03BF',
    '\u1F41': '\u03BF', '\u1F43': '\u03BF', '\u1F44': '\u03BF',
    '\u1F45': '\u03BF', '\u1F50': '\u03C5', '\u1F51': '\u03C5',
    '\u1F53': '\u03C5', '\u1F54': '\u03C5', '\u1F55': '\u03C5',
    '\u1F56': '\u03C5', '\u1F57': '\u03C5', '\u1F60': '\u03C9',
    '\u1F61': '\u03C9', '\u1F63': '\u03C9', '\u1F64': '\u03C9',
    '\u1F65': '\u03C9', '\u1F69': '\u03A9', '\u1F70': '\u03B1',
    '\u1F71': '\u03B1', '\u1F72': '\u03B5', '\u1F73': '\u03B5',
    '\u1F74': '\u03B7', '\u1F75': '\u03B7', '\u1F76': '\u03B9',
    '\u1F77': '\u03B9', '\u1F78': '\u03BF', '\u1F79': '\u03BF',
    '\u1F7A': '\u03C5', '\u1F7B': '\u03C5', '\u1F7C': '\u03C9',
    '\u1F7D': '\u03C9', '\u1F85': '\u03B1', '\u1F95': '\u03B7',
    '\u1FA0': '\u03C9', '\u1FA1': '\u03C9', '\u1FA5': '\u03C9',
    '\u1FB3': '\u03B1', '\u1FB4': '\u03B1', '\u1FB6': '\u03B1',
    '\u1FB7': '\u03B1', '\u1FC3': '\u03B7', '\u1FC6': '\u03B7',
    '\u1FC7': '\u03B7', '\u1FCE': '\u1FBF', '\u1FD6': '\u03B9',
    '\u1FDD': '\u1FFE', '\u1FDE': '\u1FFE', '\u1FE4': '\u03C1',
    '\u1FE5': '\u03C1', '\u1FE6': '\u03C5', '\u1FF3': '\u03C9',
    '\u1FF4': '\u03C9', '\u1FF6': '\u03C9', '\u1FF7': '\u03C9',
    '\u1FFD': '\u00B4',
  };

  /// Combining marks, which are dropped rather than folded.
  ///
  /// The table above handles precomposed characters; this handles text that
  /// arrives already decomposed, which is not a hypothetical — macOS hands over
  /// NFD on paste, so "Nicée" typed on a Mac can reach here as `e` + U+0301.
  /// Two spellings that Unicode considers the same word encoded to completely
  /// different vectors, and the decomposed one to `[UNK]`.
  static bool _isCombiningMark(int rune) {
    return (rune >= 0x0300 && rune <= 0x036F) || // Latin and Greek diacritics
        (rune >= 0x0483 && rune <= 0x0489) || // Cyrillic
        (rune >= 0x0591 && rune <= 0x05BD) || // Hebrew points
        (rune >= 0x0610 && rune <= 0x061A) || // Arabic
        (rune >= 0x064B && rune <= 0x065F) ||
        (rune >= 0x0730 && rune <= 0x074A) || // Syriac
        (rune >= 0x1AB0 && rune <= 0x1AFF) ||
        (rune >= 0x1DC0 && rune <= 0x1DFF) ||
        (rune >= 0x20D0 && rune <= 0x20F0) ||
        (rune >= 0xFE20 && rune <= 0xFE2F);
  }

  String _stripAccents(String text) {
    if (!text.runes.any((r) => r > 0x7F)) return text;

    final buffer = StringBuffer();
    // By rune, not by `split('')`: that walks UTF-16 code units and would cut a
    // surrogate pair in half.
    for (final rune in text.runes) {
      if (rune <= 0x7F) {
        buffer.writeCharCode(rune);
        continue;
      }
      if (_isCombiningMark(rune)) continue;
      final char = String.fromCharCode(rune);
      buffer.write(_folding[char] ?? char);
    }
    return buffer.toString();
  }

  bool _isPunctuation(int rune) {
    // BERT treats all ASCII non-alphanumerics as punctuation, plus the Unicode
    // punctuation categories.
    if (rune >= 33 && rune <= 47) return true;
    if (rune >= 58 && rune <= 64) return true;
    if (rune >= 91 && rune <= 96) return true;
    if (rune >= 123 && rune <= 126) return true;
    return rune >= 0x2000 && rune <= 0x206F;
  }

  /// BertPreTokenizer: split on whitespace, then peel punctuation into its own
  /// tokens.
  List<String> _split(String text) {
    final words = <String>[];
    final current = StringBuffer();

    void flush() {
      if (current.isNotEmpty) {
        words.add(current.toString());
        current.clear();
      }
    }

    for (final rune in text.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        flush();
      } else if (_isPunctuation(rune)) {
        flush();
        words.add(String.fromCharCode(rune));
      } else {
        current.writeCharCode(rune);
      }
    }
    flush();
    return words;
  }

  /// Greedy longest-match-first subword split, the WordPiece algorithm.
  void _wordPiece(String word, List<int> out) {
    if (word.length > 100) {
      out.add(_vocab[_unknown]!);
      return;
    }

    var start = 0;
    final pieces = <int>[];

    while (start < word.length) {
      var end = word.length;
      int? matched;

      while (start < end) {
        final piece = start == 0
            ? word.substring(start, end)
            : '$_continuation${word.substring(start, end)}';
        final id = _vocab[piece];
        if (id != null) {
          matched = id;
          break;
        }
        end--;
      }

      if (matched == null) {
        // No prefix of the remainder is in the vocabulary — the whole word is
        // unknown, not just this piece.
        out.add(_vocab[_unknown]!);
        return;
      }

      pieces.add(matched);
      start = end;
    }

    out.addAll(pieces);
  }

  /// Encode to input ids with the [CLS]/[SEP] wrapper the model expects.
  List<int> encode(String text) {
    final ids = <int>[_vocab[_classify]!];

    for (final word in _split(_normalize(text))) {
      _wordPiece(word, ids);
      // Leave room for the closing [SEP].
      if (ids.length >= maxTokens - 1) break;
    }

    if (ids.length > maxTokens - 1) {
      ids.removeRange(maxTokens - 1, ids.length);
    }
    ids.add(_vocab[_separate]!);
    return ids;
  }
}

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

  /// Drop the combining marks that NFD leaves behind. Dart has no built-in
  /// Unicode normalization, so this handles the Latin-1 range the corpus
  /// actually contains (façade, Nicæa, Chrysostom's diacritics).
  String _stripAccents(String text) {
    const folding = {
      'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
      'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y',
    };

    if (!text.runes.any((r) => r > 0x7F)) return text;

    final buffer = StringBuffer();
    for (final char in text.split('')) {
      buffer.write(folding[char] ?? char);
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

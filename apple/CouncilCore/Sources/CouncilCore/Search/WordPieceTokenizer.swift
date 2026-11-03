// Port of lib/src/services/search/wordpiece_tokenizer.dart.
//
// Golden stage: `tokenIds` in shared/golden/search/search.json.

import Foundation

/// BERT WordPiece tokenizer, matching the `bert-base-uncased` scheme the
/// bundled embedding model was trained with.
///
/// ONNX Runtime executes the model but does not tokenize. This implements the
/// same pipeline the Python side uses at build time — normalize, split, then
/// greedy longest-match against the vocabulary. Query and document vectors must
/// come from identical preprocessing or the two are not comparable.
///
/// It reproduces the Dart implementation rather than HuggingFace directly,
/// because the Dart output is what the golden fixtures pin. Two consequences
/// worth knowing:
///
/// - Words are measured and sliced in UTF-16 code units, as Dart's
///   `String.length` and `substring` are. A word longer than 100 code units is
///   `[UNK]`, and greedy matching can try a slice that ends inside a surrogate
///   pair (it is simply not in the vocabulary, as in Dart).
/// - The vocabulary is keyed by code units, not by `String`. Swift's `String`
///   hashes by canonical equivalence, so a decomposed word (Hangul jamo, say)
///   would find the precomposed vocabulary entry here and not in Dart.
public struct WordPieceTokenizer: Sendable {
    public enum LoadError: Error, Equatable {
        /// The vocabulary lacks one of `[UNK]`, `[CLS]`, `[SEP]`.
        case missingSpecialToken(String)
    }

    /// Matches the build-time truncation length.
    public static let maxTokens = SearchConstants.maxTokens

    private static let continuation: [UInt16] = Array("##".utf16)

    private let vocab: [[UInt16]: Int]
    private let unknownId: Int
    private let classifyId: Int
    private let separateId: Int

    /// Load `vocab.txt` (one token per line, id = line number), as the Dart
    /// `WordPieceTokenizer.load` reads `assets/model/vocab.txt`.
    public init(vocabularyAt url: URL) throws {
        try self.init(vocabulary: String(decoding: Data(contentsOf: url), as: UTF8.self))
    }

    /// Build from the text of `vocab.txt`.
    public init(vocabulary text: String) throws {
        var vocab: [[UInt16]: Int] = [:]
        // Split on the code unit, not on Character: Swift reads "\r\n" as one
        // Character, which `split(separator: "\n")` would never split.
        var line: [UInt16] = []
        var index = 0
        func finish() {
            // `trimRight()` with Dart's whitespace set; last write wins on a
            // repeated token, as in the Dart map.
            var end = line.count
            while end > 0 && DartText.isTrimWhitespace(line[end - 1]) { end -= 1 }
            if end > 0 { vocab[Array(line[0..<end])] = index }
            line.removeAll(keepingCapacity: true)
            index += 1
        }
        for unit in text.utf16 {
            if unit == 0x0A { finish() } else { line.append(unit) }
        }
        finish()

        func id(_ token: String) throws -> Int {
            guard let id = vocab[Array(token.utf16)] else { throw LoadError.missingSpecialToken(token) }
            return id
        }
        self.unknownId = try id("[UNK]")
        self.classifyId = try id("[CLS]")
        self.separateId = try id("[SEP]")
        self.vocab = vocab
    }

    /// Encode to input ids with the `[CLS]`/`[SEP]` wrapper the model expects.
    public func encode(_ text: String) -> [Int] {
        var ids = [classifyId]

        for word in split(normalize(text)) {
            wordPiece(word, into: &ids)
            // Leave room for the closing [SEP].
            if ids.count >= Self.maxTokens - 1 { break }
        }

        if ids.count > Self.maxTokens - 1 {
            ids.removeSubrange((Self.maxTokens - 1)...)
        }
        ids.append(separateId)
        return ids
    }

    // MARK: - Normalisation

    /// BertNormalizer: lowercase, strip control characters, strip accents.
    /// `strip_accents` is null in the model's config, which for a lowercasing
    /// BertNormalizer means accents ARE stripped — so they are stripped here too.
    func normalize(_ text: String) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        var anyNonASCII = false
        for scalar in DartText.lowercased(text).unicodeScalars {
            let rune = scalar.value
            // Skip control characters and the replacement character.
            if rune == 0 || rune == 0xFFFD { continue }
            if rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D { continue }
            if rune > 0x7F { anyNonASCII = true }
            scalars.append(scalar)
        }
        return anyNonASCII ? stripAccents(scalars) : scalars
    }

    private func stripAccents(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        // By scalar, not by UTF-16 unit, so a surrogate pair is never cut.
        for scalar in scalars {
            if scalar.value <= 0x7F {
                out.append(scalar)
                continue
            }
            if Self.isCombiningMark(scalar.value) { continue }
            if let folded = Self.folding[scalar.value] {
                out.append(Unicode.Scalar(folded)!)
            } else {
                out.append(scalar)
            }
        }
        return out
    }

    /// Fold a character to what the build-time tokenizer leaves of it.
    ///
    /// `assets/model/tokenizer.json` declares
    /// `BertNormalizer(strip_accents: null, lowercase: true)`, and in that
    /// configuration strip_accents follows lowercase — so the Python side that
    /// embedded the corpus decomposed every character to NFD and dropped every
    /// combining mark. The Dart side once had a hand-written table of thirty
    /// precomposed Latin-1 letters, which is a different function.
    ///
    /// What the difference cost: a word containing any character the table
    /// missed was not partially matched, it was discarded whole, because
    /// `wordPiece` emits a single `[UNK]` when no prefix of the remainder is in
    /// the vocabulary. The vocabulary holds all 24 bare Greek letters and none
    /// of the accented forms, so "ὁμοούσιος" encoded to exactly one token —
    /// `[UNK]` — and the query vector for the most load-bearing word in the
    /// Arian controversy was built from nothing. Folded, it is
    /// `ο ##μ ##ο ##ου ##σ ##ι ##ος`, which is what the documents were embedded
    /// as. "Grégoire" was `[UNK]` too, and is now `greg ##oire`.
    ///
    /// Generated from the shipped corpus rather than written by hand: every
    /// non-ASCII character in the bundled units, and its lowercase form, folded
    /// through Python's unicodedata the same way the build does. 131 entries.
    /// Copied verbatim from the Dart table — it is the contract, not
    /// `Unicode.Scalar` decomposition, whose coverage is wider.
    static let folding: [UInt32: UInt32] = [
        0x00C1: 0x41, 0x00C2: 0x41, 0x00C3: 0x41, 0x00C9: 0x45,
        0x00CA: 0x45, 0x00CC: 0x49, 0x00CE: 0x49, 0x00D1: 0x4E,
        0x00DC: 0x55, 0x00E0: 0x61, 0x00E1: 0x61, 0x00E2: 0x61,
        0x00E3: 0x61, 0x00E4: 0x61, 0x00E7: 0x63, 0x00E8: 0x65,
        0x00E9: 0x65, 0x00EA: 0x65, 0x00EB: 0x65, 0x00EC: 0x69,
        0x00ED: 0x69, 0x00EE: 0x69, 0x00EF: 0x69, 0x00F1: 0x6E,
        0x00F2: 0x6F, 0x00F3: 0x6F, 0x00F4: 0x6F, 0x00F6: 0x6F,
        0x00F9: 0x75, 0x00FA: 0x75, 0x00FB: 0x75, 0x00FC: 0x75,
        0x0115: 0x65, 0x011B: 0x65, 0x014D: 0x6F, 0x014F: 0x6F,
        0x0160: 0x53, 0x0161: 0x73, 0x017E: 0x7A, 0x0387: 0x00B7,
        0x03AC: 0x03B1, 0x03AD: 0x03B5, 0x03AE: 0x03B7,
        0x03AF: 0x03B9, 0x03CA: 0x03B9, 0x03CC: 0x03BF,
        0x03CD: 0x03C5, 0x1F00: 0x03B1, 0x1F01: 0x03B1,
        0x1F02: 0x03B1, 0x1F04: 0x03B1, 0x1F05: 0x03B1,
        0x1F0C: 0x0391, 0x1F0D: 0x0391, 0x1F10: 0x03B5,
        0x1F11: 0x03B5, 0x1F12: 0x03B5, 0x1F13: 0x03B5,
        0x1F14: 0x03B5, 0x1F15: 0x03B5, 0x1F18: 0x0395,
        0x1F20: 0x03B7, 0x1F21: 0x03B7, 0x1F22: 0x03B7,
        0x1F24: 0x03B7, 0x1F25: 0x03B7, 0x1F26: 0x03B7,
        0x1F29: 0x0397, 0x1F30: 0x03B9, 0x1F31: 0x03B9,
        0x1F32: 0x03B9, 0x1F34: 0x03B9, 0x1F35: 0x03B9,
        0x1F36: 0x03B9, 0x1F37: 0x03B9, 0x1F40: 0x03BF,
        0x1F41: 0x03BF, 0x1F43: 0x03BF, 0x1F44: 0x03BF,
        0x1F45: 0x03BF, 0x1F50: 0x03C5, 0x1F51: 0x03C5,
        0x1F53: 0x03C5, 0x1F54: 0x03C5, 0x1F55: 0x03C5,
        0x1F56: 0x03C5, 0x1F57: 0x03C5, 0x1F60: 0x03C9,
        0x1F61: 0x03C9, 0x1F63: 0x03C9, 0x1F64: 0x03C9,
        0x1F65: 0x03C9, 0x1F69: 0x03A9, 0x1F70: 0x03B1,
        0x1F71: 0x03B1, 0x1F72: 0x03B5, 0x1F73: 0x03B5,
        0x1F74: 0x03B7, 0x1F75: 0x03B7, 0x1F76: 0x03B9,
        0x1F77: 0x03B9, 0x1F78: 0x03BF, 0x1F79: 0x03BF,
        0x1F7A: 0x03C5, 0x1F7B: 0x03C5, 0x1F7C: 0x03C9,
        0x1F7D: 0x03C9, 0x1F85: 0x03B1, 0x1F95: 0x03B7,
        0x1FA0: 0x03C9, 0x1FA1: 0x03C9, 0x1FA5: 0x03C9,
        0x1FB3: 0x03B1, 0x1FB4: 0x03B1, 0x1FB6: 0x03B1,
        0x1FB7: 0x03B1, 0x1FC3: 0x03B7, 0x1FC6: 0x03B7,
        0x1FC7: 0x03B7, 0x1FCE: 0x1FBF, 0x1FD6: 0x03B9,
        0x1FDD: 0x1FFE, 0x1FDE: 0x1FFE, 0x1FE4: 0x03C1,
        0x1FE5: 0x03C1, 0x1FE6: 0x03C5, 0x1FF3: 0x03C9,
        0x1FF4: 0x03C9, 0x1FF6: 0x03C9, 0x1FF7: 0x03C9,
        0x1FFD: 0x00B4,
    ]

    /// Combining marks, which are dropped rather than folded.
    ///
    /// The table above handles precomposed characters; this handles text that
    /// arrives already decomposed, which is not a hypothetical — macOS hands
    /// over NFD on paste, so "Nicée" typed on a Mac can reach here as `e` +
    /// U+0301. Two spellings that Unicode considers the same word encoded to
    /// completely different vectors, and the decomposed one to `[UNK]`.
    static func isCombiningMark(_ rune: UInt32) -> Bool {
        (0x0300...0x036F).contains(rune) || // Latin and Greek diacritics
            (0x0483...0x0489).contains(rune) || // Cyrillic
            (0x0591...0x05BD).contains(rune) || // Hebrew points
            (0x0610...0x061A).contains(rune) || // Arabic
            (0x064B...0x065F).contains(rune) ||
            (0x0730...0x074A).contains(rune) || // Syriac
            (0x1AB0...0x1AFF).contains(rune) ||
            (0x1DC0...0x1DFF).contains(rune) ||
            (0x20D0...0x20F0).contains(rune) ||
            (0xFE20...0xFE2F).contains(rune)
    }

    // MARK: - Pre-tokenisation

    /// BERT treats all ASCII non-alphanumerics as punctuation, plus the
    /// General Punctuation block.
    static func isPunctuation(_ rune: UInt32) -> Bool {
        if rune >= 33 && rune <= 47 { return true }
        if rune >= 58 && rune <= 64 { return true }
        if rune >= 91 && rune <= 96 { return true }
        if rune >= 123 && rune <= 126 { return true }
        return rune >= 0x2000 && rune <= 0x206F
    }

    /// BertPreTokenizer: split on whitespace, then peel punctuation into its
    /// own tokens. Words come back as UTF-16 code units, the unit Dart's
    /// `wordPiece` measures and slices in.
    func split(_ scalars: [Unicode.Scalar]) -> [[UInt16]] {
        var words: [[UInt16]] = []
        var current: [UInt16] = []

        func flush() {
            if !current.isEmpty {
                words.append(current)
                current.removeAll()
            }
        }

        for scalar in scalars {
            let rune = scalar.value
            if rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D {
                flush()
            } else if Self.isPunctuation(rune) {
                flush()
                words.append(Array(scalar.utf16))
            } else {
                current.append(contentsOf: scalar.utf16)
            }
        }
        flush()
        return words
    }

    // MARK: - WordPiece

    /// Greedy longest-match-first subword split, the WordPiece algorithm.
    private func wordPiece(_ word: [UInt16], into out: inout [Int]) {
        if word.count > 100 {
            out.append(unknownId)
            return
        }

        var start = 0
        var pieces: [Int] = []
        var piece: [UInt16] = []

        while start < word.count {
            var end = word.count
            var matched: Int?

            while start < end {
                piece.removeAll(keepingCapacity: true)
                if start > 0 { piece.append(contentsOf: Self.continuation) }
                piece.append(contentsOf: word[start..<end])
                if let id = vocab[piece] {
                    matched = id
                    break
                }
                end -= 1
            }

            guard let matched else {
                // No prefix of the remainder is in the vocabulary — the whole
                // word is unknown, not just this piece.
                out.append(unknownId)
                return
            }

            pieces.append(matched)
            start = end
        }

        out.append(contentsOf: pieces)
    }
}

import 'vector_index.dart';

/// Combines a lexical ranking with a semantic one.
///
/// The two find different things and neither subsumes the other. FTS5 nails
/// exact terminology — "homoousion", a quoted phrase, a proper name — but
/// returns nothing when the user's words and the text's words differ.
/// Embeddings match meaning across vocabulary but drift on rare proper nouns
/// and can rank a merely topical passage above an exact quotation.
///
/// Fusion is by reciprocal rank rather than by score. Raw BM25 and cosine
/// values are on incomparable scales, and normalizing them requires knowing
/// each distribution; rank position needs no such calibration, which is why
/// reciprocal rank fusion is the standard choice.
class HybridRanker {
  /// Dampens the top of each list so one engine's first result cannot
  /// automatically win. 60 is the value from the original RRF paper and is
  /// what most implementations use.
  static const double k = 60.0;

  /// Fuse two ranked lists of unit ids into one.
  ///
  /// Items are scored `1 / (k + rank)` in each list they appear in, summed,
  /// then sorted. Appearing in both lists is what promotes a result — which is
  /// the property we want, since agreement between a lexical and a semantic
  /// engine is a strong signal.
  static List<int> fuse({
    required List<int> lexical,
    required List<int> semantic,
    double lexicalWeight = 1.0,
    double semanticWeight = 1.0,
    int? limit,
  }) {
    final scores = <int, double>{};

    void accumulate(List<int> ranking, double weight) {
      for (var i = 0; i < ranking.length; i++) {
        scores.update(
          ranking[i],
          (existing) => existing + weight / (k + i + 1),
          ifAbsent: () => weight / (k + i + 1),
        );
      }
    }

    accumulate(lexical, lexicalWeight);
    accumulate(semantic, semanticWeight);

    final ordered = scores.keys.toList()
      ..sort((a, b) {
        final byScore = scores[b]!.compareTo(scores[a]!);
        // Deterministic ordering for equal scores keeps results stable across
        // runs, which matters for both tests and user trust.
        return byScore != 0 ? byScore : a.compareTo(b);
      });

    if (limit != null && ordered.length > limit) {
      return ordered.sublist(0, limit);
    }
    return ordered;
  }

  /// Keep only the best-scoring chunk per content unit.
  ///
  /// Overlapping chunks mean one passage can occupy several of the top slots.
  /// Without this, a single long work crowds out every other source and the
  /// answer ends up citing one author repeatedly.
  static List<ChunkMatch> bestPerUnit(List<ChunkMatch> matches) {
    final best = <int, ChunkMatch>{};
    for (final match in matches) {
      final existing = best[match.contentUnitId];
      if (existing == null || match.score > existing.score) {
        best[match.contentUnitId] = match;
      }
    }

    return best.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
  }
}

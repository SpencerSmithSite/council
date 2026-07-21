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

  /// Enforce variety across sources and traditions.
  ///
  /// Relevance alone does not produce a usable comparative answer. The corpus
  /// is lopsided — hundreds of patristic sources against a handful for most
  /// other traditions — so a purely relevance-ordered list fills with whichever
  /// tradition happens to be largest, and the one passage that would let a
  /// reader compare gets pushed off the end. Heidelberg's question on infant
  /// baptism is the best semantic match for a question about Reformed infant
  /// baptism and still lost every slot to patristic material.
  ///
  /// Items are taken in relevance order while their source and tradition are
  /// under quota. Anything skipped is held back, then used to top the list up
  /// if the quotas leave it short.
  ///
  /// The quotas are therefore a **reservation, not a hard ceiling**: their job
  /// is to guarantee that minority sources reach the result set, not to punish
  /// the majority. Once that is secured, topping up with more of the larger
  /// tradition adds context and costs nothing — whereas returning a short list
  /// would hand the model less to work with for no benefit. A caller wanting a
  /// strict ceiling should pass a smaller `limit`.
  ///
  /// Ordering within the final set stays relevance-ordered, so this is a no-op
  /// when results are already varied.
  static List<T> diversify<T>(
    List<T> ranked, {
    required Object? Function(T) sourceOf,
    required Object? Function(T) traditionOf,
    required int limit,
    int maxPerSource = 2,
    int? maxPerTradition,
  }) {
    // Default: no tradition may take more than half the slots, so at least two
    // are always represented when the corpus can manage it.
    final traditionCap = maxPerTradition ?? (limit / 2).ceil();

    final selected = <T>[];
    final deferred = <T>[];
    final perSource = <Object?, int>{};
    final perTradition = <Object?, int>{};

    for (final item in ranked) {
      if (selected.length >= limit) {
        deferred.add(item);
        continue;
      }

      final source = sourceOf(item);
      final tradition = traditionOf(item);

      if ((perSource[source] ?? 0) >= maxPerSource ||
          (perTradition[tradition] ?? 0) >= traditionCap) {
        deferred.add(item);
        continue;
      }

      selected.add(item);
      perSource[source] = (perSource[source] ?? 0) + 1;
      perTradition[tradition] = (perTradition[tradition] ?? 0) + 1;
    }

    // A quota can leave the set short — a query genuinely answered by one
    // source should still return results rather than an artificially thin list.
    for (final item in deferred) {
      if (selected.length >= limit) break;
      selected.add(item);
    }

    return selected;
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

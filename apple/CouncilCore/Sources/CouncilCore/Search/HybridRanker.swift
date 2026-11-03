// Port of lib/src/services/search/hybrid_ranker.dart (`fuse` and
// `diversify`; `bestPerUnit` is not ported — nothing in retrieval calls it,
// only its own unit test).
//
// Golden stage: `rag.fused` in shared/golden/search/search.json.

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
public enum HybridRanker {
    /// Dampens the top of each list so one engine's first result cannot
    /// automatically win.
    public static let k = SearchConstants.rrfK

    /// Fuse the ranked lists of unit ids into one.
    ///
    /// Items are scored `weight / (k + rank)` in each list they appear in,
    /// summed, then sorted. Appearing in more than one list is what promotes a
    /// result — which is the property we want, since agreement between engines
    /// that work differently is a strong signal.
    ///
    /// `tags` is the third engine: units carrying the topic tags extracted from
    /// the query. It used to be concatenated onto `lexical` by the caller,
    /// which broke the promotion rule in both directions. A unit found by both
    /// FTS and tags appeared twice in one list and collected two contributions,
    /// scoring as though a further engine had agreed about it when only one
    /// had; and every tag result sat below every FTS result whatever its own
    /// rank, so its ranking carried no information at all.
    ///
    /// Ties are everywhere — a unit at position *i* in one list scores the same
    /// as a different unit at position *i* in another — and are broken by
    /// ascending unit id. For tied sums to be bit-identical to the Dart ones,
    /// contributions are added in the same order (lexical, semantic, tags),
    /// each computed as `weight / ((k + i) + 1)` in Double.
    public static func fuse(
        lexical: [Int],
        semantic: [Int],
        tags: [Int] = [],
        lexicalWeight: Double = 1.0,
        semanticWeight: Double = 1.0,
        tagWeight: Double = 1.0,
        limit: Int? = nil
    ) -> [Int] {
        var scores: [Int: Double] = [:]

        func accumulate(_ ranking: [Int], _ weight: Double) {
            // One rank per list, which is what RRF is defined over. A repeated
            // id inside a single ranking is not two engines agreeing, and
            // scoring it twice invents agreement nobody reported. Positions are
            // left as they fall, since a duplicate's rank in the list it came
            // from is still its rank.
            var counted = Set<Int>()
            for (i, id) in ranking.enumerated() where counted.insert(id).inserted {
                let contribution = weight / (k + Double(i) + 1)
                if let existing = scores[id] {
                    scores[id] = existing + contribution
                } else {
                    scores[id] = contribution
                }
            }
        }

        accumulate(lexical, lexicalWeight)
        accumulate(semantic, semanticWeight)
        accumulate(tags, tagWeight)

        // Deterministic ordering for equal scores keeps results stable across
        // runs, which matters for both tests and user trust.
        let ordered = scores.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }.map(\.key)

        if let limit, ordered.count > limit {
            return Array(ordered.prefix(limit))
        }
        return ordered
    }

    /// Enforce variety across sources and traditions.
    ///
    /// Relevance alone does not produce a usable comparative answer. The corpus
    /// is lopsided — hundreds of patristic sources against a handful for most
    /// other traditions — so a purely relevance-ordered list fills with
    /// whichever tradition happens to be largest, and the one passage that
    /// would let a reader compare gets pushed off the end. Heidelberg's
    /// question on infant baptism is the best semantic match for a question
    /// about Reformed infant baptism and still lost every slot to patristic
    /// material.
    ///
    /// Items are taken in relevance order while their source and tradition are
    /// under quota. Anything skipped is held back, then used to top the list up
    /// if the quotas leave it short.
    ///
    /// The quotas are therefore a **reservation, not a hard ceiling**: their
    /// job is to guarantee that minority sources reach the result set, not to
    /// punish the majority. Once that is secured, topping up with more of the
    /// larger tradition adds context and costs nothing — whereas returning a
    /// short list would hand the model less to work with for no benefit. A
    /// caller wanting a strict ceiling should pass a smaller `limit`.
    ///
    /// Ordering within the final set stays relevance-ordered, so this is a
    /// no-op when results are already varied.
    public static func diversify<T, Source: Hashable, Tradition: Hashable>(
        _ ranked: [T],
        sourceOf: (T) -> Source,
        traditionOf: (T) -> Tradition,
        limit: Int,
        maxPerSource: Int = 2,
        maxPerTradition: Int? = nil
    ) -> [T] {
        // Default: no tradition may take more than half the slots, so at least
        // two are always represented when the corpus can manage it.
        let traditionCap = maxPerTradition ?? Int((Double(limit) / 2).rounded(.up))

        var selected: [T] = []
        var deferred: [T] = []
        var perSource: [Source: Int] = [:]
        var perTradition: [Tradition: Int] = [:]

        for item in ranked {
            if selected.count >= limit {
                deferred.append(item)
                continue
            }

            let source = sourceOf(item)
            let tradition = traditionOf(item)

            if perSource[source, default: 0] >= maxPerSource
                || perTradition[tradition, default: 0] >= traditionCap {
                deferred.append(item)
                continue
            }

            selected.append(item)
            perSource[source, default: 0] += 1
            perTradition[tradition, default: 0] += 1
        }

        // A quota can leave the set short — a query genuinely answered by one
        // source should still return results rather than an artificially thin
        // list.
        for item in deferred {
            if selected.count >= limit { break }
            selected.append(item)
        }

        return selected
    }
}

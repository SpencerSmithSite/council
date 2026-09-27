import 'package:flutter_test/flutter_test.dart';
import 'package:council/src/services/search/hybrid_ranker.dart';
import 'package:council/src/services/search/vector_index.dart';

ChunkMatch _match(int chunkId, int unitId, double score) => ChunkMatch(
      chunkId: chunkId,
      contentUnitId: unitId,
      charStart: 0,
      charEnd: 100,
      score: score,
    );

void main() {
  _threeEngineTests();
  group('fuse', () {
    test('promotes results both engines agree on', () {
      // 7 is second in both lists; 1 and 9 each top one list but are absent
      // from the other. Agreement should win.
      final fused = HybridRanker.fuse(
        lexical: [1, 7, 3],
        semantic: [9, 7, 4],
      );

      expect(fused.first, 7);
    });

    test('keeps results that appear in only one engine', () {
      // Semantic-only hits are the whole point — they are the ones lexical
      // search cannot find.
      final fused = HybridRanker.fuse(lexical: [1, 2], semantic: [8, 9]);
      expect(fused, containsAll([1, 2, 8, 9]));
    });

    test('handles an empty ranking from either side', () {
      expect(HybridRanker.fuse(lexical: [1, 2], semantic: []), [1, 2]);
      expect(HybridRanker.fuse(lexical: [], semantic: [3, 4]), [3, 4]);
      expect(HybridRanker.fuse(lexical: [], semantic: []), isEmpty);
    });

    test('weighting shifts the balance between engines', () {
      // Same rank in each list; the weight decides which wins.
      final lexicalFavoured = HybridRanker.fuse(
        lexical: [1],
        semantic: [2],
        lexicalWeight: 2.0,
      );
      expect(lexicalFavoured.first, 1);

      final semanticFavoured = HybridRanker.fuse(
        lexical: [1],
        semantic: [2],
        semanticWeight: 2.0,
      );
      expect(semanticFavoured.first, 2);
    });

    test('respects the limit', () {
      final fused = HybridRanker.fuse(
        lexical: [1, 2, 3, 4, 5],
        semantic: [6, 7, 8],
        limit: 3,
      );
      expect(fused.length, 3);
    });

    test('is deterministic when scores tie', () {
      final a = HybridRanker.fuse(lexical: [5, 3], semantic: [3, 5]);
      final b = HybridRanker.fuse(lexical: [5, 3], semantic: [3, 5]);
      expect(a, b);
    });
  });

  _diversityTests();

  group('bestPerUnit', () {
    test('collapses overlapping chunks from one unit to its best', () {
      // Overlapping chunks mean one long work can otherwise occupy every slot.
      final collapsed = HybridRanker.bestPerUnit([
        _match(1, 100, 0.9),
        _match(2, 100, 0.7),
        _match(3, 100, 0.5),
        _match(4, 200, 0.6),
      ]);

      expect(collapsed.length, 2);
      expect(collapsed.first.chunkId, 1);
      expect(collapsed.map((m) => m.contentUnitId), containsAll([100, 200]));
    });

    test('returns results sorted by score', () {
      final collapsed = HybridRanker.bestPerUnit([
        _match(1, 10, 0.2),
        _match(2, 20, 0.9),
        _match(3, 30, 0.5),
      ]);

      expect(
        collapsed.map((m) => m.score).toList(),
        [0.9, 0.5, 0.2],
      );
    });

    test('handles an empty input', () {
      expect(HybridRanker.bestPerUnit([]), isEmpty);
    });
  });
}

/// A retrieval result reduced to what diversification cares about.
class _Result {
  final String source;
  final String tradition;
  const _Result(this.source, this.tradition);
  @override
  String toString() => '$source/$tradition';
}

void _diversityTests() {
  List<_Result> diversify(List<_Result> input, {int limit = 6}) =>
      HybridRanker.diversify<_Result>(
        input,
        sourceOf: (r) => r.source,
        traditionOf: (r) => r.tradition,
        limit: limit,
      );

  group('diversify', () {
    test('lets a minority tradition through when it is out-ranked', () {
      // The real failure: a Reformed passage is the best answer but sits below
      // a wall of patristic hits, so relevance order alone buries it.
      final ranked = [
        for (var i = 0; i < 10; i++) _Result('Augustine $i', 'Early Church'),
        const _Result('Heidelberg', 'Reformed'),
      ];

      final result = diversify(ranked);
      expect(
        result.map((r) => r.tradition),
        contains('Reformed'),
        reason: 'the only Reformed source must survive',
      );
    });

    test('admits every minority tradition before topping up', () {
      final ranked = [
        for (var i = 0; i < 20; i++) _Result('Father $i', 'Early Church'),
        const _Result('Heidelberg', 'Reformed'),
        const _Result('Trent', 'Catholic'),
      ];

      final result = diversify(ranked);
      expect(result.map((r) => r.tradition).toSet(),
          containsAll(['Early Church', 'Reformed', 'Catholic']));
    });

    test('stops one source monopolising the result', () {
      // One long work can otherwise occupy every slot with its own chapters.
      final ranked = [
        for (var i = 0; i < 8; i++) const _Result('City of God', 'Early Church'),
        const _Result('Confessions', 'Early Church'),
        const _Result('Heidelberg', 'Reformed'),
      ];

      final result = diversify(ranked);
      expect(result.map((r) => r.source).toSet().length, greaterThan(1));
      expect(result.map((r) => r.source), contains('Heidelberg'));
    });

    test('quotas are a reservation, not a ceiling', () {
      // Once the minority is secured, the majority tops the list up rather
      // than the caller receiving a needlessly short result.
      final ranked = [
        for (var i = 0; i < 20; i++) _Result('Father $i', 'Early Church'),
        const _Result('Heidelberg', 'Reformed'),
      ];

      final result = diversify(ranked);
      expect(result.length, 6, reason: 'tops up to the requested limit');
      expect(result.map((r) => r.source), contains('Heidelberg'));
    });

    test('refills rather than returning a short list', () {
      // If everything really does come from one source, a thin result is worse
      // than a repetitive one.
      final ranked = [
        for (var i = 0; i < 6; i++) const _Result('Only Source', 'Early Church'),
      ];

      expect(diversify(ranked).length, 6);
    });

    test('preserves relevance order within the selection', () {
      final ranked = [
        const _Result('A', 'Early Church'),
        const _Result('B', 'Reformed'),
        const _Result('C', 'Catholic'),
      ];

      expect(diversify(ranked).map((r) => r.source), ['A', 'B', 'C']);
    });

    test('is a no-op on already-varied results', () {
      final ranked = [
        const _Result('A', 'Early Church'),
        const _Result('B', 'Reformed'),
        const _Result('C', 'Catholic'),
        const _Result('D', 'Lutheran'),
      ];

      expect(diversify(ranked, limit: 4), ranked);
    });

    test('handles an empty input', () {
      expect(diversify(const []), isEmpty);
    });
  });
}

/// RRF scores an item once per ranking it appears in, and summing those is what
/// makes agreement between engines the thing that promotes a result.
///
/// searchForRAG used to concatenate the tag results onto the FTS results and
/// pass the pair as one "lexical" list, which broke that rule twice over.
void _threeEngineTests() {
  group('one rank per list', () {
    test('a duplicate inside one ranking is not counted twice', () {
      // 7 is listed twice by a single engine and found by no other; 3 is found
      // by two engines that agree. Scored per appearance, 7 collects
      // 1/61 + 1/62 = 0.03252 and 3 collects 1/63 + 1/61 = 0.03226, so the
      // duplicate wins — one engine repeating itself outranking two engines
      // agreeing, which is the opposite of what RRF is for.
      final fused = HybridRanker.fuse(
        lexical: [7, 7, 3],
        semantic: [3],
      );

      expect(fused.first, 3,
          reason: 'a unit two engines found beats one listed twice by one');
    });

    test('a repeated id appears once in the output', () {
      expect(HybridRanker.fuse(lexical: [4, 4, 4], semantic: []), [4]);
    });
  });

  group('tags are a third engine', () {
    test('a tag ranking on its own contributes results', () {
      final fused = HybridRanker.fuse(
        lexical: const [],
        semantic: const [],
        tags: [11, 12],
      );
      expect(fused, [11, 12]);
    });

    test('a unit found by tags and FTS outranks one found by FTS alone', () {
      final fused = HybridRanker.fuse(
        lexical: [1, 2],
        semantic: const [],
        tags: [2],
      );

      // 2 is second in the lexical list and first in the tag list. Two engines
      // agreeing about it should beat one engine's top hit.
      expect(fused.first, 2);
    });

    test("a tag result's own rank carries information", () {
      // Concatenated, every tag result sat below every FTS result whatever its
      // position, so the order within the tag list said nothing.
      final first = HybridRanker.fuse(
        lexical: const [],
        semantic: const [],
        tags: [20, 21],
      );
      final reversed = HybridRanker.fuse(
        lexical: const [],
        semantic: const [],
        tags: [21, 20],
      );

      expect(first, [20, 21]);
      expect(reversed, [21, 20]);
    });

    test('weights apply to the tag ranking too', () {
      final favoured = HybridRanker.fuse(
        lexical: [1],
        semantic: const [],
        tags: [2],
        lexicalWeight: 0.1,
        tagWeight: 1.0,
      );
      expect(favoured.first, 2);
    });
  });
}

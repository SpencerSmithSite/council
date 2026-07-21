import 'package:flutter_test/flutter_test.dart';
import 'package:theology_app/src/services/search/hybrid_ranker.dart';
import 'package:theology_app/src/services/search/vector_index.dart';

ChunkMatch _match(int chunkId, int unitId, double score) => ChunkMatch(
      chunkId: chunkId,
      contentUnitId: unitId,
      charStart: 0,
      charEnd: 100,
      score: score,
    );

void main() {
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

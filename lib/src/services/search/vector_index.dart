import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// One scored chunk from the vector index.
class ChunkMatch {
  final int chunkId;
  final int contentUnitId;
  final int charStart;
  final int charEnd;
  final double score;

  const ChunkMatch({
    required this.chunkId,
    required this.contentUnitId,
    required this.charStart,
    required this.charEnd,
    required this.score,
  });

  ChunkMatch withScore(double newScore) => ChunkMatch(
        chunkId: chunkId,
        contentUnitId: contentUnitId,
        charStart: charStart,
        charEnd: charEnd,
        score: newScore,
      );
}

/// In-memory nearest-neighbour search over the precomputed chunk embeddings.
///
/// The vectors are L2-normalized and quantized to int8 at build time, so
/// cosine similarity is just a dot product, and the whole index is ~20 MB for
/// 53,500 chunks — small enough to hold resident and scan exhaustively. At
/// this scale an approximate index (HNSW, IVF) would add a dependency and a
/// build step to save a few milliseconds.
class VectorIndex {
  static const int dims = 384;

  /// Quantization scale used by tools/build_embeddings.py.
  static const double _scale = 127.0;

  final Int8List _vectors;
  final Int32List _chunkIds;
  final Int32List _unitIds;
  final Int32List _starts;
  final Int32List _ends;

  VectorIndex._(
    this._vectors,
    this._chunkIds,
    this._unitIds,
    this._starts,
    this._ends,
  );

  int get length => _chunkIds.length;

  /// How many rows to pull per round trip. See [load].
  static const int _pageSize = 20000;

  /// Load the index from the database, a page at a time.
  ///
  /// Costs a few seconds and ~165 MB at 430,000 chunks, so callers should do
  /// this once, lazily, and off the first frame.
  ///
  /// **Why this is paged.** It was a single query returning every row, which
  /// was fine at the 115,000 chunks this was written against and stopped being
  /// fine at 430,000: the whole result set — 165 MB of BLOBs — is marshalled
  /// across the platform channel and materialised as a `List<Map>` before the
  /// first byte is read. sqflite serialises every database operation through
  /// one queue, so for as long as that call ran, *nothing else in the app
  /// could touch the database*. In testing it blocked the queue for around
  /// four minutes, and the symptom was not a slow search but a library that
  /// stopped answering.
  ///
  /// Paging fixes the blocking rather than the total time: each page is a
  /// short operation, and anything else queued runs between them. Keyset
  /// pagination (`chunk_id > last`) rather than OFFSET, which rescans.
  static Future<VectorIndex> load(Database db) async {
    final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM chunk_embeddings'),
        ) ??
        0;

    final vectors = Int8List(count * dims);
    final chunkIds = Int32List(count);
    final unitIds = Int32List(count);
    final starts = Int32List(count);
    final ends = Int32List(count);

    var i = 0;
    var after = -1;
    while (i < count) {
      final rows = await db.rawQuery('''
        SELECT e.chunk_id, e.vector, c.content_unit_id, c.char_start, c.char_end
        FROM chunk_embeddings e
        JOIN content_chunks c ON e.chunk_id = c.id
        WHERE e.chunk_id > ?
        ORDER BY e.chunk_id
        LIMIT ?
      ''', [after, _pageSize]);
      if (rows.isEmpty) break;

      for (final row in rows) {
        // The count and the join can disagree if a chunk lost its parent; stop
        // rather than write past the end of the buffers.
        if (i >= count) break;
        final blob = row['vector'] as Uint8List;
        vectors.setRange(
          i * dims,
          i * dims + dims,
          blob.buffer.asInt8List(blob.offsetInBytes, dims),
        );
        chunkIds[i] = row['chunk_id'] as int;
        unitIds[i] = row['content_unit_id'] as int;
        starts[i] = row['char_start'] as int;
        ends[i] = row['char_end'] as int;
        i++;
      }
      after = rows.last['chunk_id'] as int;
    }

    // A chunk whose parent unit is gone yields fewer rows than the count. Trim
    // rather than leave zeroed vectors, which would score as valid neighbours.
    if (i < count) {
      return VectorIndex._(
        Int8List.sublistView(vectors, 0, i * dims),
        Int32List.sublistView(chunkIds, 0, i),
        Int32List.sublistView(unitIds, 0, i),
        Int32List.sublistView(starts, 0, i),
        Int32List.sublistView(ends, 0, i),
      );
    }

    return VectorIndex._(vectors, chunkIds, unitIds, starts, ends);
  }

  /// Top [limit] chunks by cosine similarity to [query].
  ///
  /// [query] must be L2-normalized and produced by the same model that built
  /// the index — vectors from a different model are not comparable.
  List<ChunkMatch> search(Float32List query, {int limit = 20}) {
    assert(query.length == dims, 'query must be $dims-dimensional');

    // A small max-heap would be tidier, but with limit ~20 an insertion into a
    // sorted list of that size is cheaper than heap bookkeeping.
    final best = <ChunkMatch>[];
    var floor = -2.0;

    for (var i = 0; i < _chunkIds.length; i++) {
      final base = i * dims;
      var dot = 0.0;
      for (var d = 0; d < dims; d++) {
        dot += _vectors[base + d] * query[d];
      }
      final score = dot / _scale;

      if (best.length < limit || score > floor) {
        final match = ChunkMatch(
          chunkId: _chunkIds[i],
          contentUnitId: _unitIds[i],
          charStart: _starts[i],
          charEnd: _ends[i],
          score: score,
        );

        var at = best.length;
        while (at > 0 && best[at - 1].score < score) {
          at--;
        }
        best.insert(at, match);
        if (best.length > limit) best.removeLast();
        floor = best.last.score;
      }
    }

    return best;
  }
}

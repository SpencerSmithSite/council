import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'query_encoder.dart';
import 'vector_index.dart';

/// Semantic retrieval over the precomputed corpus vectors.
///
/// Kept separate from [DatabaseService] on purpose. The encoder runs through a
/// native plugin, so anything importing it transitively cannot run under
/// `flutter test`; isolating it here keeps the unit suite free of the platform
/// dependency and makes the degraded path explicit — if the model fails to
/// load, search stays lexical rather than the app failing to start.
class SemanticSearch {
  final QueryEncoder _encoder;
  final VectorIndex _index;

  SemanticSearch._(this._encoder, this._index);

  int get vectorCount => _index.length;

  /// Load the model and vector index, or return null if either fails.
  ///
  /// Deliberately non-fatal. Semantic search is an improvement over lexical
  /// search, not a precondition for it, and a device that cannot run the model
  /// should still be able to read the library.
  static Future<SemanticSearch?> tryLoad(Database db) async {
    try {
      final encoder = await QueryEncoder.load();
      final index = await VectorIndex.load(db);
      return SemanticSearch._(encoder, index);
    } catch (error, stack) {
      debugPrint('Semantic search unavailable, falling back to lexical: $error');
      debugPrintStack(stackTrace: stack);
      return null;
    }
  }

  /// Content unit ids ranked by semantic similarity, best first.
  ///
  /// [allowedUnitIds] applies a recognised scope. Both engines must honour it:
  /// scoping only the lexical side lets unscoped semantic hits back in through
  /// fusion, which is how a question about the Council of Trent kept returning
  /// Carthage and Nicaea.
  Future<List<int>> rankedUnits(
    String query, {
    int limit = 30,
    Set<int>? allowedUnitIds,
  }) async {
    final vector = await _encoder.encode(query);

    // Ask for more chunks than units wanted: several chunks of one long work
    // routinely occupy the top of the list, and they collapse to a single unit.
    final matches = _index.search(vector, limit: limit * 6);

    final units = <int>[];
    final seen = <int>{};
    for (final match in matches) {
      if (allowedUnitIds != null && !allowedUnitIds.contains(match.contentUnitId)) {
        continue;
      }
      if (seen.add(match.contentUnitId)) {
        units.add(match.contentUnitId);
        if (units.length >= limit) break;
      }
    }
    return units;
  }

  void dispose() => _encoder.dispose();
}

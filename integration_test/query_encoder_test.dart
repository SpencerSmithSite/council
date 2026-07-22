import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/search/query_encoder.dart';
import 'package:council/src/services/search/vector_index.dart';

/// The query encoder, exercised on a real device against the real corpus.
///
/// This cannot be unit tested: the model runs through a native plugin, so
/// `flutter test` never executes it. And the failure mode that matters is not
/// a crash — it is a query vector that lands in a slightly different space
/// from the corpus vectors, which produces plausible-looking nonsense with no
/// error at all. So the assertions are about *retrieval behaving sensibly*,
/// not about the plumbing running.
///
///     flutter test integration_test/query_encoder_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late QueryEncoder encoder;
  late VectorIndex index;

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
    encoder = await QueryEncoder.load();
    index = await VectorIndex.load(db.database);
  });

  tearDownAll(() => encoder.dispose());

  double cosine(Float32List a, Float32List b) {
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  test('produces a normalized vector of the expected width', () async {
    final vector = await encoder.encode('How is a person saved?');

    expect(vector.length, QueryEncoder.dims);
    final norm = math.sqrt(cosine(vector, vector));
    expect(norm, closeTo(1.0, 0.01),
        reason: 'corpus vectors are L2-normalized; queries must be too');
  });

  test('places related questions nearer than unrelated ones', () async {
    // The encoder could return well-formed vectors that encode nothing useful.
    // This is the cheapest check that it encodes *meaning*.
    final saved = await encoder.encode('How is a person saved?');
    final justified = await encoder.encode('justification by faith alone');
    final bishops = await encoder.encode('how many bishops ordain a bishop');

    expect(cosine(saved, justified), greaterThan(cosine(saved, bishops)));
  });

  test('the index loaded and covers the corpus', () {
    expect(index.length, greaterThan(50000));
  });

  group('semantic retrieval against the real corpus', () {
    test('finds passages sharing meaning but not vocabulary', () async {
      // The gap lexical search structurally cannot close: this query shares
      // only the word "saved" with the confessional language of justification.
      final vector = await encoder.encode('How is a person saved?');
      final matches = index.search(vector, limit: 20);

      expect(matches, isNotEmpty);
      expect(matches.first.score, greaterThan(0.3),
          reason: 'a weak best-match suggests vectors from different spaces');

      final units = matches.map((m) => m.contentUnitId).toSet();
      final rows = await db.database.rawQuery('''
        SELECT DISTINCT s.title FROM content_units cu
        JOIN sources s ON cu.source_id = s.id
        WHERE cu.id IN (${List.filled(units.length, '?').join(',')})
      ''', units.toList());

      expect(rows, isNotEmpty);
    });

    test('scores are ordered and within the valid cosine range', () async {
      final vector = await encoder.encode('the Lord\'s Supper');
      final matches = index.search(vector, limit: 10);

      for (var i = 1; i < matches.length; i++) {
        expect(matches[i].score, lessThanOrEqualTo(matches[i - 1].score));
      }
      for (final match in matches) {
        expect(match.score, inInclusiveRange(-1.01, 1.01));
      }
    });

    test('different questions retrieve different passages', () async {
      // If the encoder collapsed every input to a similar vector, retrieval
      // would look fine per-query and be identical across queries.
      final baptism = index.search(await encoder.encode('infant baptism'),
          limit: 10);
      final angels = index.search(await encoder.encode('the nature of angels'),
          limit: 10);

      final overlap = baptism.map((m) => m.chunkId).toSet()
        ..retainAll(angels.map((m) => m.chunkId).toSet());
      expect(overlap.length, lessThan(3),
          reason: 'unrelated questions should not return the same passages');
    });
  });
}

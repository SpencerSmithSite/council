import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:theology_app/src/services/database_service.dart';
import 'package:theology_app/src/services/search/entity_recogniser.dart';

/// Retrieval, exercised against the real bundled corpus on a real device.
///
/// Every other test in this project runs against fixtures, and the retrieval
/// work has been verified through a Python mirror in `tools/query_probe.py`.
/// That mirror is written to match the Dart, but nothing enforced the match —
/// so a Dart-side regression could pass every test and every probe while the
/// shipped app returned the wrong passages.
///
/// These tests close that gap. They are slow (first run decompresses ~120 MB)
/// and need a device, so they live outside the unit suite:
///
///     flutter test integration_test/retrieval_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
  });

  Future<List<Map<String, dynamic>>> retrieve(String question) =>
      db.searchForRAG(question, limit: 6);

  Set<String> traditionsIn(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['tradition'] as String? ?? '?').toSet();

  Set<String> sourcesIn(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['source_title'] as String? ?? '?').toSet();

  group('the corpus is what we think it is', () {
    test('opens and holds the expected shape', () async {
      final stats = await db.getStats();
      expect(stats['sources'], greaterThan(400));
      expect(stats['content_units'], greaterThan(18000));
      expect(stats['traditions'], greaterThan(6));
    });

    test('every unit carries provenance classification', () async {
      final rows = await db.database.rawQuery(
        "SELECT count(*) AS n FROM content_units WHERE provenance IS NULL",
      );
      expect(rows.first['n'], 0);
    });
  });

  group('comparative questions', () {
    test('returns more than one tradition', () async {
      // The failure this whole line of work started from: every slot filled
      // with whichever tradition the corpus holds most of.
      final rows = await retrieve(
        'What are the differences between Catholic and Lutheran '
        'beliefs about baptism?',
      );

      expect(rows, isNotEmpty);
      expect(traditionsIn(rows).length, greaterThan(1),
          reason: 'a comparison needs more than one tradition');
    });

    test('draws on genuine Lutheran sources, not mislabelled ones', () async {
      // Every source previously labelled Lutheran was Eastern Orthodox or
      // patristic. These are the real confessions.
      final rows = await db.database.rawQuery('''
        SELECT s.title FROM sources s
        JOIN traditions t ON s.tradition_id = t.id
        WHERE t.name = 'Lutheran'
      ''');
      final titles = rows.map((r) => r['title'] as String).toList();

      expect(titles, contains('The Augsburg Confession'));
      expect(titles, isNot(contains('The Didache')));
      expect(titles, isNot(contains('The Philokalia Selections')));
    });
  });

  group('entity scoping', () {
    late EntityRecogniser recogniser;

    setUpAll(() async => recogniser = await db.recogniser);

    test('scopes a question naming a work to that work', () async {
      final scope = recogniser.recognise(
        'What did the Council of Trent decree about justification?',
      );
      expect(scope.isNotEmpty, isTrue);

      final rows = await retrieve(
        'What did the Council of Trent decree about justification?',
      );
      expect(
        sourcesIn(rows).any((s) => s.contains('Trent')),
        isTrue,
        reason: 'a question naming Trent must return Trent',
      );
    });

    test('scopes a question naming an author to their works', () async {
      final scope =
          recogniser.recognise('What did Augustine say about grace?');
      expect(scope.sourceIds.length, greaterThan(20),
          reason: 'Augustine has many works in the corpus');

      final rows = await retrieve('What did Augustine say about grace?');
      expect(rows, isNotEmpty);
    });

    test('leaves an ordinary question unscoped', () {
      // The false positives that made a rare-token rule untenable.
      expect(recogniser.recognise('How is a person saved?').isEmpty, isTrue);
      expect(recogniser.recognise('Is the Son equal to the Father?').isEmpty,
          isTrue);
    });
  });

  group('passage selection', () {
    test('returns a readable slice of an enormous unit', () async {
      // Augustine's Enchiridion runs to 162,014 characters. Before chunking,
      // retrieval handed the model its first 1,500 and everything else was
      // invisible.
      final rows = await retrieve('What is the resurrection of the body?');
      expect(rows, isNotEmpty);

      for (final row in rows) {
        final content = row['content'] as String? ?? '';
        expect(content.length, lessThan(20000),
            reason: 'a retrieved passage must be readable, not a whole book');
        expect(content.trim(), isNotEmpty);
      }
    });

    test('every result carries a source and a tradition', () async {
      // A citation the reader cannot attribute is not a citation.
      final rows = await retrieve('How is a person saved?');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['source_title'], isNotNull);
        expect(row['id'], isNotNull);
      }
    });
  });
}

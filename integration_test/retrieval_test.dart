import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/search/entity_recogniser.dart';
import 'package:council/src/services/search/semantic_search.dart';
import 'package:council/src/services/packs/pack_service.dart';

/// Retrieval, exercised against the real bundled corpus on a real device.
///
/// Every other test in this project runs against fixtures, and the retrieval
/// work has been verified through a Python mirror in `tools/query_probe.py`.
/// That mirror is written to match the Dart, but nothing enforced the match —
/// so a Dart-side regression could pass every test and every probe while the
/// shipped app returned the wrong passages.
///
/// These tests close that gap. They are slow and need a device, so they live
/// outside the unit suite.
///
/// Since the corpus was split into a bundled core and downloadable packs, most
/// of the patristic material is no longer present by default — so this suite
/// installs the packs first when told where to find them. Without them it
/// still runs, over the core corpus, and the tests that need the fathers say
/// plainly that they were skipped rather than quietly passing:
///
///     python3 tools/build_packs.py --write
///     (cd dist/packs && python3 -m http.server 8765 &)
///     flutter test integration_test/retrieval_test.dart -d macos \
///       --dart-define=PACKS_URL=http://127.0.0.1:8765/manifest.json
/// Where to fetch content packs from, if this run should exercise the full
/// library rather than the bundled core. Empty means core only.
const _packsUrl = String.fromEnvironment('PACKS_URL', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;

  final fullCorpus = _packsUrl.isNotEmpty;
  final needsPacks = fullCorpus
      ? null
      : 'needs the content packs — see the note at the top of this file';

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
    if (!fullCorpus) return;

    final packs = PackService(db.database, manifestUrl: _packsUrl);
    final manifest = await packs.fetchManifest();
    // Every collection, so the suite runs against the whole library. They
    // overlap heavily; installing them all still fetches each fragment once.
    for (final collection in manifest.collections) {
      await packs.install(
        collection,
        manifest,
        corpusVersion: DatabaseService.corpusVersion,
      );
    }
    await db.semantic?.reload();
    packs.dispose();
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
      // The app now bundles Scripture and nothing else; every other tradition
      // arrives as a collection. So "the expected shape" depends entirely on
      // whether they were installed.
      expect(stats['sources'], greaterThan(fullCorpus ? 400 : 0));
      expect(stats['content_units'], greaterThan(fullCorpus ? 18000 : 1000));
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
    }, skip: needsPacks);

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
    }, skip: needsPacks);
  });

  group('citations can be checked', () {
    test('every result carries what a citation needs to show', () async {
      final rows = await retrieve('What is baptism for?');
      expect(rows, isNotEmpty);

      for (final row in rows) {
        expect(row['source_title'], isNotNull);
        expect(row.containsKey('tradition'), isTrue);
        // Present as a key even when null: the UI distinguishes "traced to a
        // published edition" from "origin never recorded", and it can only do
        // that if the column is selected at all. Dropping it from the query
        // would silently turn every citation into an unverifiable one.
        expect(row.containsKey('source_url'), isTrue);
        expect(row.containsKey('license'), isTrue);
      }
    });

    test('traceable and untraceable sources are distinguishable', () async {
      final counts = await db.database.rawQuery('''
        SELECT
          SUM(CASE WHEN source_url IS NULL OR source_url = '' THEN 1 ELSE 0 END)
            AS untraceable,
          COUNT(*) AS total
        FROM sources
      ''');
      final untraceable = counts.first['untraceable'] as int;
      final total = counts.first['total'] as int;

      expect(total, greaterThan(0));
      // Not asserted to be zero: some legacy sources genuinely have no
      // recorded origin, and the point of this work is that the app says so
      // rather than hiding it. This guards the *ability to tell*.
      expect(untraceable, lessThan(total));
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
    }, skip: needsPacks);

    test('scopes a question naming an author to their works', () async {
      final scope =
          recogniser.recognise('What did Augustine say about grace?');
      expect(scope.sourceIds.length, greaterThan(20),
          reason: 'Augustine has many works in the corpus');

      final rows = await retrieve('What did Augustine say about grace?');
      expect(rows, isNotEmpty);
    }, skip: needsPacks);

    test('leaves an ordinary question unscoped', () {
      // The false positives that made a rare-token rule untenable.
      expect(recogniser.recognise('How is a person saved?').isEmpty, isTrue);
      expect(recogniser.recognise('Is the Son equal to the Father?').isEmpty,
          isTrue);
    });
  });

  group('hybrid retrieval', hybridTests);

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

/// Hybrid retrieval — lexical and semantic together, as the app runs it.
///
/// Kept in this file rather than the encoder's so it exercises the real
/// `searchForRAG` path, including scope, fusion and diversification.
void hybridTests() {
  late DatabaseService db;

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
    db.semantic = await SemanticSearch.tryLoad(db.database);
  });

  test('semantic search is actually available', () {
    expect(db.semantic, isNotNull,
        reason: 'the model should load on a supported platform');
    // The core corpus carries 2,683 vectors; the full library carries 54,854.
    expect(db.semantic!.vectorCount,
        greaterThan(_packsUrl.isEmpty ? 2000 : 50000));
  });

  test('answers a question whose words are not in the answer', () async {
    // The whole point of the semantic half: this shares almost no vocabulary
    // with confessional language about justification.
    final rows = await db.searchForRAG('How is a person saved?', limit: 6);
    expect(rows, isNotEmpty);
    for (final row in rows) {
      expect((row['content'] as String).trim(), isNotEmpty);
    }
  });

  test('degrades to lexical when the model is absent', () async {
    final lexicalOnly = DatabaseService();
    await lexicalOnly.initialize();
    lexicalOnly.semantic = null;

    final rows = await lexicalOnly.searchForRAG('baptism', limit: 5);
    expect(rows, isNotEmpty,
        reason: 'no model must mean worse search, not broken search');
  });
}

import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

/// Content packs, exercised end to end against the real corpus.
///
/// The packs are served from a local HTTP server rather than stubbed, so one
/// test covers download, checksum verification and the SQL merge together.
/// Testing the merge alone would miss the failure that actually matters: a
/// pack that downloads perfectly and lands in the database without being
/// indexed, which looks like a successful install and silently returns nothing.
///
/// The packs are served by an ordinary HTTP server started outside the app,
/// and its URL is passed in. Serving them from inside the test does not work:
/// the macOS app sandbox refuses to open files outside the app container, and
/// it fails at *read* time rather than at `existsSync`, so the obvious version
/// of this reports the directory as present and then dies mid-request.
///
///     python3 tools/build_packs.py --write
///     (cd dist/packs && python3 -m http.server 8765 &)
///     flutter test integration_test/pack_test.dart -d macos \
///       --dart-define=PACKS_URL=http://127.0.0.1:8765/manifest.json
///
/// With no PACKS_URL these tests skip. That is a real risk — a suite that
/// silently skips looks identical to one that passes — so the skip reason
/// names the flag rather than saying something vague about configuration.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late PackService packs;

  const packsUrl = String.fromEnvironment('PACKS_URL', defaultValue: '');

  setUpAll(() async {
    if (packsUrl.isEmpty) return;
    db = DatabaseService();
    await db.initialize();
    packs = PackService(db.database, manifestUrl: packsUrl);

    // The database persists between runs, so a run that failed partway leaves
    // packs installed and the next run measures against the wrong baseline.
    for (final id in await packs.installedIds()) {
      await packs.uninstall(id);
    }
  });

  /// How many search results are actually Augustine's writing.
  ///
  /// Counting results outright does not work: the core corpus is confessional,
  /// so this query already fills the result limit with creeds and catechisms
  /// that share these ordinary words. What has to change is *whose* text comes
  /// back — and that is the author, not the title, since Augustine's works are
  /// catalogued as "Confessions" and "City of God" with his name nowhere in
  /// them.
  Future<int> augustineHits() async {
    final rows = await db.search('the grace of God and free will', limit: 40);
    if (rows.isEmpty) return 0;

    final ids = rows.map((r) => r['id'] as int).toList();
    final marks = List.filled(ids.length, '?').join(',');
    return Sqflite.firstIntValue(await db.database.rawQuery('''
      SELECT COUNT(*) FROM content_units cu
      JOIN sources s ON cu.source_id = s.id
      WHERE cu.id IN ($marks) AND s.author LIKE 'Augustine%'
    ''', ids))!;
  }

  tearDownAll(() {
    if (packsUrl.isNotEmpty) packs.dispose();
  });

  Future<int> countSources() async => Sqflite.firstIntValue(
        await db.database.rawQuery('SELECT COUNT(*) FROM sources'),
      )!;

  Future<int> countUnits() async => Sqflite.firstIntValue(
        await db.database.rawQuery('SELECT COUNT(*) FROM content_units'),
      )!;

  group('content packs', () {
    test('the manifest lists packs and declares its corpus version', () async {
      final manifest = await packs.fetchManifest();

      expect(manifest.corpusVersion, DatabaseService.corpusVersion,
          reason: 'a pack built from a different corpus can reuse ids the app '
              'has already assigned to different text');
      expect(manifest.packs, isNotEmpty);
      expect(manifest.packs.first.sha256, hasLength(64));
    });

    test('a pack from another corpus build is refused', () async {
      final manifest = await packs.fetchManifest();

      await expectLater(
        packs.install(
          manifest.packs.first,
          corpusVersion: DatabaseService.corpusVersion,
          manifestCorpusVersion: DatabaseService.corpusVersion + 1,
        ),
        throwsA(isA<PackException>()),
      );
    });

    test('installing adds content that was not searchable before', () async {
      final manifest = await packs.fetchManifest();
      final pack = manifest.packs.firstWhere((p) => p.id == 'fathers-augustine');

      // The core corpus is confessional; Augustine ships in a pack. If he is
      // already reachable, the test proves nothing about installing.
      final before = await augustineHits();
      expect(before, 0, reason: 'Augustine should not be in the core corpus');
      final sourcesBefore = await countSources();
      final unitsBefore = await countUnits();

      var sawProgress = false;
      await packs.install(
        pack,
        corpusVersion: DatabaseService.corpusVersion,
        manifestCorpusVersion: manifest.corpusVersion,
        onProgress: (received, total) => sawProgress = received > 0,
      );

      expect(sawProgress, isTrue, reason: 'a 5 MB download needs feedback');
      expect(await countSources(), sourcesBefore + pack.sources);
      expect(await countUnits(), unitsBefore + pack.units);
      expect((await packs.installedIds()), contains(pack.id));

      // The point of the whole exercise: the new text is *retrievable*, which
      // means it reached the FTS index and not merely the tables.
      expect(await augustineHits(), greaterThan(0),
          reason: 'installed content that search cannot reach is not installed');
    });

    test('installing twice is a no-op rather than a duplicate', () async {
      final manifest = await packs.fetchManifest();
      final pack = manifest.packs.firstWhere((p) => p.id == 'fathers-augustine');

      final sources = await countSources();
      await packs.install(
        pack,
        corpusVersion: DatabaseService.corpusVersion,
        manifestCorpusVersion: manifest.corpusVersion,
      );
      expect(await countSources(), sources,
          reason: 'a second install must not insert the rows again');
    });

    test('a corrupted download is rejected, not installed', () async {
      final manifest = await packs.fetchManifest();
      final real = manifest.packs.firstWhere((p) => p.id == 'fathers-chrysostom');
      final tampered = PackInfo(
        id: real.id,
        name: real.name,
        description: real.description,
        file: real.file,
        bytes: real.bytes,
        sha256: '0' * 64,
        sources: real.sources,
        units: real.units,
        chunks: real.chunks,
      );

      final sources = await countSources();
      await expectLater(
        packs.install(
          tampered,
          corpusVersion: DatabaseService.corpusVersion,
          manifestCorpusVersion: manifest.corpusVersion,
        ),
        throwsA(isA<PackException>()),
      );
      expect(await countSources(), sources,
          reason: 'a pack that fails verification must not be merged');
      expect(await packs.installedIds(), isNot(contains(tampered.id)));
    });

    test('uninstalling removes the content and the index entries', () async {
      final manifest = await packs.fetchManifest();
      final pack = manifest.packs.firstWhere((p) => p.id == 'fathers-augustine');

      final sources = await countSources();
      await packs.uninstall(pack.id);

      expect(await countSources(), sources - pack.sources);
      expect(await packs.installedIds(), isNot(contains(pack.id)));

      // The index is external-content FTS5 with no sync triggers, so deleting
      // rows without rebuilding leaves matches pointing at text that is gone.
      // Both assertions matter: the content is unreachable again, and nothing
      // search still returns has lost its row.
      expect(await augustineHits(), 0);
      for (final row in await db.search('the grace of God and free will',
          limit: 20)) {
        expect(await db.getContentUnit(row['id'] as int), isNotNull,
            reason: 'search returned a unit that no longer exists');
      }
    });
  }, skip: packsUrl.isEmpty
      ? 'serve dist/packs and pass --dart-define=PACKS_URL=<manifest url>'
      : null);
}

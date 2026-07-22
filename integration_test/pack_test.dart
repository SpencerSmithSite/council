import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

/// Content collections, exercised end to end against the real corpus.
///
/// Fragments are served by an ordinary HTTP server started outside the app and
/// its URL passed in. Serving them from inside the test does not work: the
/// macOS app sandbox refuses to open files outside the app container, and it
/// fails at *read* time rather than at `existsSync`, so the obvious version
/// reports the directory present and then dies mid-request.
///
///     python3 tools/build_packs.py --write
///     (cd dist/packs && python3 -m http.server 8765 &)
///     flutter test integration_test/pack_test.dart -d macos \
///       --dart-define=PACKS_URL=http://127.0.0.1:8765/manifest.json
///
/// With no PACKS_URL these skip. A suite that silently skips looks identical to
/// one that passes, so the skip reason names the flag.
///
/// The tests that download carry a raised timeout. Against a local server they
/// finish in a second; against the published release they move tens of
/// megabytes over a CDN, and the default 30-second limit expires mid-download
/// and reports as a failure indistinguishable from a real one.
const _networkTimeout = Timeout(Duration(minutes: 10));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late PackService packs;

  const packsUrl = String.fromEnvironment('PACKS_URL', defaultValue: '');

  Future<void> reset() async {
    for (final id in await packs.installedCollections()) {
      await packs.uninstall(id);
    }
  }

  setUpAll(() async {
    if (packsUrl.isEmpty) return;
    db = DatabaseService();
    await db.initialize();
    packs = PackService(db.database, manifestUrl: packsUrl);
    // The database persists between runs, so a run that failed partway leaves
    // content installed and the next run measures against the wrong baseline.
    await reset();
  });

  tearDownAll(() async {
    if (packsUrl.isNotEmpty) {
      await reset();
      packs.dispose();
    }
  });

  Future<int> countSources() async => Sqflite.firstIntValue(
        await db.database.rawQuery('SELECT COUNT(*) FROM sources'),
      )!;

  /// How many search results are actually Augustine's writing.
  ///
  /// Counting results outright does not work: the core corpus is confessional,
  /// so this query already fills the result limit with creeds and catechisms
  /// sharing these ordinary words. What has to change is *whose* text comes
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

  Collection find(PackManifest m, String id) =>
      m.collections.firstWhere((c) => c.id == id);

  group('content collections', () {
    test('the manifest declares fragments, collections and a corpus version',
        () async {
      final manifest = await packs.fetchManifest();

      expect(manifest.corpusVersion, DatabaseService.corpusVersion,
          reason: 'a fragment built from a different corpus can reuse ids the '
              'app has already assigned to different text');
      expect(manifest.fragments, isNotEmpty);
      expect(manifest.collections, isNotEmpty);
      expect(manifest.fragments.first.sha256, hasLength(64));

      // Every collection must resolve. A collection naming a fragment that was
      // never published would install silently and hold nothing.
      final published = manifest.fragments.map((f) => f.id).toSet();
      for (final collection in manifest.collections) {
        expect(collection.fragments, isNotEmpty, reason: collection.id);
        expect(published.containsAll(collection.fragments), isTrue,
            reason: '${collection.id} references an unpublished fragment');
      }
    });

    test('installing makes content retrievable that was not before', () async {
      final manifest = await packs.fetchManifest();
      final augustine = find(manifest, 'author-augustine');

      expect(await augustineHits(), 0,
          reason: 'Augustine should not be in the bundled core');

      var sawProgress = false;
      await packs.install(augustine, manifest,
          corpusVersion: DatabaseService.corpusVersion,
          onProgress: (received, total) => sawProgress = received > 0);

      expect(sawProgress, isTrue, reason: 'a multi-MB download needs feedback');
      expect(await packs.installedCollections(), contains('author-augustine'));
      expect(await packs.installedFragments(), contains('f-augustine'));

      // The point of the exercise: the new text is *retrievable*, meaning it
      // reached the FTS index and not merely the tables.
      expect(await augustineHits(), greaterThan(0),
          reason: 'installed content search cannot reach is not installed');
    }, timeout: _networkTimeout);

    test('a second collection sharing a fragment downloads nothing', () async {
      final manifest = await packs.fetchManifest();
      final fathers = find(manifest, 'nicene-fathers');

      // This is what the two-layer design buys. "Nicene & Post-Nicene Writers"
      // includes Augustine, who is already here, so only the rest is fetched.
      final before = manifest.bytesToInstall(
          fathers, await packs.installedFragments());
      final standalone =
          fathers.fragments.map((f) => manifest.fragment(f)!.bytes).reduce(
                (a, b) => a + b,
              );

      expect(before, lessThan(standalone),
          reason: 'the shared fragment should not be quoted again');
      expect(standalone - before, manifest.fragment('f-augustine')!.bytes);
    });

    test('removing a collection keeps fragments another still needs', () async {
      final manifest = await packs.fetchManifest();
      final fathers = find(manifest, 'nicene-fathers');

      await packs.install(fathers, manifest,
          corpusVersion: DatabaseService.corpusVersion);
      expect(await packs.installedFragments(), contains('f-chrysostom'));

      // Both installed collections claim f-augustine; only one is removed.
      await packs.uninstall('nicene-fathers');

      expect(await packs.installedFragments(), isNot(contains('f-chrysostom')),
          reason: 'Chrysostom was needed only by the collection just removed');
      expect(await packs.installedFragments(), contains('f-augustine'),
          reason: 'Augustine is still required by author-augustine');
      expect(await augustineHits(), greaterThan(0),
          reason: 'reference counting must not delete text still claimed');
    }, timeout: _networkTimeout);

    test('removing the last claimant does delete the content', () async {
      await packs.uninstall('author-augustine');

      expect(await packs.installedFragments(), isEmpty);
      expect(await augustineHits(), 0);

      // External-content FTS5 has no sync triggers, so this catches a stale
      // index: matches surviving their rows return passages that cannot open.
      for (final row in await db.search('the grace of God and free will',
          limit: 20)) {
        expect(await db.getContentUnit(row['id'] as int), isNotNull,
            reason: 'search returned a unit that no longer exists');
      }
    }, timeout: _networkTimeout);

    test('installing twice is a no-op rather than a duplicate', () async {
      final manifest = await packs.fetchManifest();
      final anglican = find(manifest, 'tradition-anglican');

      await packs.install(anglican, manifest,
          corpusVersion: DatabaseService.corpusVersion);
      final sources = await countSources();

      await packs.install(anglican, manifest,
          corpusVersion: DatabaseService.corpusVersion);
      expect(await countSources(), sources,
          reason: 'a second install must not insert the rows again');

      await packs.uninstall('tradition-anglican');
    }, timeout: _networkTimeout);

    test('content from another corpus build is refused', () async {
      final manifest = await packs.fetchManifest();
      await expectLater(
        packs.install(find(manifest, 'tradition-anglican'), manifest,
            corpusVersion: DatabaseService.corpusVersion + 1),
        throwsA(isA<PackException>()),
      );
    });

    test('a corrupted download is rejected, not installed', () async {
      final manifest = await packs.fetchManifest();
      final real = manifest.fragment('f-anglican')!;
      final tampered = PackManifest(
        corpusVersion: manifest.corpusVersion,
        fragments: [
          Fragment(
            id: real.id,
            file: real.file,
            bytes: real.bytes,
            sha256: '0' * 64,
            sources: real.sources,
            units: real.units,
            chunks: real.chunks,
          )
        ],
        collections: manifest.collections,
      );

      final sources = await countSources();
      await expectLater(
        packs.install(find(tampered, 'tradition-anglican'), tampered,
            corpusVersion: DatabaseService.corpusVersion),
        throwsA(isA<PackException>()),
      );
      expect(await countSources(), sources,
          reason: 'content failing verification must not be merged');
      expect(await packs.installedFragments(), isNot(contains('f-anglican')));
    }, timeout: _networkTimeout);
  }, skip: packsUrl.isEmpty
      ? 'serve dist/packs and pass --dart-define=PACKS_URL=<manifest url>'
      : null);
}

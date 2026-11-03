import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:council/src/services/packs/pack_service.dart';

/// The pack golden fixtures in `shared/golden/packs/`, replayed through the
/// real PackService.
///
/// The native Apple app reimplements pack download, verification and merge,
/// and has to end up with exactly the database this app ends up with. The
/// fixtures are the contract: a tiny bundled core, packs cut from it by
/// tools/build_packs.py, and the expected tables after every step of every
/// scenario in `scenarios.json`. This test is what keeps them true of the
/// Flutter app — if it fails after a change to pack_service.dart, either the
/// change is a regression or the fixtures need regenerating deliberately with
/// `python3 tools/build_pack_goldens.py` (and the Swift side updating to
/// match). See the README there for what each file is.
///
/// Fragments are served by a MockClient reading the scenario's directory, so
/// download, checksum, gunzip, ATTACH and merge all run for real against the
/// fixture bytes; only the socket is replaced.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

final _golden = p.join('shared', 'golden', 'packs');

dynamic _readJson(String relative) =>
    jsonDecode(File(p.join(_golden, relative)).readAsStringSync());

/// A scenario directory served as if it were the published release. Records
/// which fragment files were requested, in order.
class _Release {
  _Release(this.dir);
  final String dir;
  final requests = <String>[];

  String get manifestUrl => 'https://golden.invalid/$dir/manifest.json';

  late final http.Client client = MockClient.streaming((request, _) async {
    final name = request.url.pathSegments.last;
    if (name != 'manifest.json') requests.add(name);
    final file = File(p.join(_golden, dir, name));
    if (!file.existsSync()) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    final bytes = file.readAsBytesSync();
    const chunk = 1024;
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += chunk)
          bytes.sublist(i, (i + chunk).clamp(0, bytes.length)),
      ]),
      200,
      contentLength: bytes.length,
    );
  });
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Object? _jsonable(Object? value) =>
    value is Uint8List ? {'blob': _hex(value)} : value;

/// The same view of the database that tools/build_pack_goldens.py records:
/// every table the expected states name, ordered by all columns left to right,
/// `installed_at` left out; and the FTS index read from the index itself
/// (fts5vocab), so a missing or stale entry is a difference.
Future<Map<String, dynamic>> _dump(Database db, Iterable<String> tables) async {
  final out = <String, dynamic>{};
  for (final table in tables) {
    final columns = [
      for (final c in await db.rawQuery('PRAGMA table_info($table)'))
        if (c['name'] != 'installed_at') c['name'] as String,
    ];
    final order = [for (var i = 1; i <= columns.length; i++) '$i'].join(', ');
    final rows = await db
        .rawQuery('SELECT ${columns.join(', ')} FROM $table ORDER BY $order');
    out[table] = {
      'columns': columns,
      'rows': [
        for (final row in rows) [for (final c in columns) _jsonable(row[c])],
      ],
    };
  }

  await db.execute('CREATE VIRTUAL TABLE temp.golden_vocab '
      'USING fts5vocab(main, content_fts, instance)');
  final tokens = <String, Map<String, List<String>>>{};
  for (final row in await db.rawQuery('SELECT doc, col, term FROM '
      'temp.golden_vocab ORDER BY doc, col, offset')) {
    tokens
        .putIfAbsent('${row['doc']}', () => {})
        .putIfAbsent(row['col'] as String, () => [])
        .add(row['term'] as String);
  }
  await db.execute('DROP TABLE temp.golden_vocab');

  return {
    'tables': out,
    'fts': {
      for (final doc in tokens.entries)
        doc.key: {
          for (final col in doc.value.entries) col.key: col.value.join(' '),
        },
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final plan = _readJson('scenarios.json') as Map<String, dynamic>;
  final appIdSpace = plan['appIdSpace'] as int;
  final baseState = _readJson(plan['baseState'] as String) as Map;
  final tables = (baseState['tables'] as Map).keys.cast<String>().toList();

  late Directory support;
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    support = await Directory.systemTemp.createTemp('council-pack-golden');
    PathProviderPlatform.instance = _FakePathProvider(support.path);
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    // The bundled core, then the bookkeeping DatabaseService.initialize adds.
    await db.execute(
        File(p.join(_golden, plan['baseSql'] as String)).readAsStringSync());
    await PackService.createTables(db);
  });

  tearDown(() async {
    await db.close();
    if (await support.exists()) await support.delete(recursive: true);
  });

  Future<void> expectState(String file, String where) async {
    final expected = _readJson(file) as Map<String, dynamic>;
    final actual = await _dump(db, tables);
    for (final table in tables) {
      expect(actual['tables'][table], expected['tables'][table],
          reason: '$where: table $table differs from $file');
    }
    expect(actual['fts'], expected['fts'],
        reason: '$where: the FTS index differs from $file');
    // And the index agrees with content_units — throws if it does not.
    await db.execute(
        "INSERT INTO content_fts(content_fts) VALUES('integrity-check')");
  }

  group('the fixtures', () {
    test('describe this build of the app', () {
      // A fixture for another id space or embedding model would be testing a
      // gate this app does not have. Regenerate after changing either.
      expect(appIdSpace, DatabaseService.idSpace);
      expect(plan['appEmbeddingModel'], DatabaseService.embeddingModel);
      final published = _readJson('manifest.json') as Map<String, dynamic>;
      expect(published['idSpace'], DatabaseService.idSpace);
      expect(published['embeddingModel'], DatabaseService.embeddingModel);
    });

    test('carry checksums that match their files, but for the one corrupted '
        'on purpose', () {
      final mismatched = <String>[];
      for (final scenario in plan['scenarios'] as List) {
        final dir = scenario['dir'] as String;
        final manifest = _readJson(p.join(dir, 'manifest.json')) as Map;
        for (final fragment in manifest['fragments'] as List) {
          final file = File(p.join(_golden, dir, fragment['file'] as String));
          final bytes = file.readAsBytesSync();
          if (sha256.convert(bytes).toString() != fragment['sha256'] ||
              bytes.length != fragment['bytes']) {
            mismatched.add(p.posix.join(dir, fragment['file'] as String));
          }
        }
      }
      expect(mismatched, ['negative/checksum-mismatch/f-beta.db.gz']);
    });

    test('the bundled core loads to the base state', () async {
      await expectState(plan['baseState'] as String, 'base');
    });
  });

  for (final scenario in (plan['scenarios'] as List).cast<Map>()) {
    final name = scenario['name'] as String;
    test('scenario $name', () async {
      // A step may be served from a release other than its scenario's: a
      // fragment republished between two installs.
      final services = <PackService>[];
      Future<(_Release, PackService, PackManifest)> serve(String dir) async {
        final release = _Release(dir);
        final service = PackService(
          db,
          client: release.client,
          manifestUrl: release.manifestUrl,
        );
        services.add(service);
        return (release, service, await service.fetchManifest());
      }

      final scenarioRelease = await serve(scenario['dir'] as String);

      var number = 0;
      for (final step in (scenario['steps'] as List).cast<Map>()) {
        number++;
        final where = '$name step $number (${step['op']} '
            '${step['collection'] ?? step['fragment']})';
        final (release, service, manifest) = step['dir'] == null
            ? scenarioRelease
            : await serve(step['dir'] as String);
        release.requests.clear();

        Object? error;
        try {
          switch (step['op']) {
            case 'install':
              await service.install(
                manifest.collections
                    .firstWhere((c) => c.id == step['collection']),
                manifest,
                idSpace: step['appIdSpace'] as int? ?? appIdSpace,
              );
            case 'uninstall':
              await service.uninstall(step['collection'] as String);
            case 'markStale':
              await db.update('installed_fragments', {'sha256': 'stale'},
                  where: 'id = ?', whereArgs: [step['fragment']]);
            default:
              fail('$where: unknown op');
          }
        } catch (e) {
          error = e;
        }

        final throws = step['throws'] as Map?;
        if (throws == null) {
          expect(error, isNull, reason: '$where: should succeed');
        } else if (throws['type'] == 'PackException') {
          expect(error, isA<PackException>(), reason: where);
          expect(error.toString(), throws['message'], reason: where);
        } else {
          expect(throws['type'], 'DatabaseException');
          expect(error, isA<DatabaseException>(), reason: where);
          expect(error.toString(), contains(throws['messageContains']),
              reason: where);
        }

        if (step.containsKey('downloads')) {
          expect(release.requests, step['downloads'],
              reason: '$where: fragments fetched');
        }
        if (step.containsKey('state')) {
          await expectState(step['state'] as String, where);
        }

        // Success or failure, nothing is left behind: no attached pack, no
        // archive or expanded database in the workspace.
        final attached = await db.rawQuery('PRAGMA database_list');
        expect(attached.map((r) => r['name']), isNot(contains('pack')),
            reason: '$where: pack left attached');
        final workspace = Directory(p.join(support.path, 'packs'));
        if (workspace.existsSync()) {
          expect(workspace.listSync(), isEmpty,
              reason: '$where: temporary files left in the workspace');
        }
      }
      for (final service in services) {
        service.dispose();
      }
    });
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:council/src/services/packs/pack_service.dart';

/// An installed pack's vectors must have been built by the model this app
/// encodes queries with.
///
/// PackManifest.embeddingsCompatibleWith was written for exactly this and had no
/// caller anywhere — install checked only the id space. The failure it guards
/// against is silent in a way that makes it worth a test: vectors from one model
/// compared against queries from another are noise, and every checksum, row count
/// and fragment record stays perfectly correct while semantic retrieval stops
/// working. Both DatabaseService.embeddingModel and the manifest field carry doc
/// comments describing that outcome as the reason they exist.
void main() {
  late Database corpus;
  late PackService packs;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    corpus = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await PackService.createTables(corpus);
    packs = PackService(corpus);
  });

  tearDown(() async => corpus.close());

  String manifestWith(String? embeddingModel) => '''
  {
    "corpusVersion": 16,
    "idSpace": ${DatabaseService.idSpace},
    ${embeddingModel == null ? '' : '"embeddingModel": "$embeddingModel",'}
    "fragments": [
      {"id": "f-augustine", "file": "f-augustine.db.gz", "bytes": 1024,
       "sha256": "aa", "sources": 1, "units": 1, "chunks": 1}
    ],
    "collections": [
      {"id": "author-augustine", "kind": "author", "name": "Augustine of Hippo",
       "description": "", "fragments": ["f-augustine"]}
    ]
  }
  ''';

  Future<void> install(String? embeddingModel) {
    final manifest = PackManifest.parse(manifestWith(embeddingModel));
    return packs.install(
      manifest.collections.single,
      manifest,
      idSpace: DatabaseService.idSpace,
    );
  }

  test('a pack built by a different embedding model is refused', () async {
    await expectLater(
      install('some-other-model-v9'),
      throwsA(isA<PackException>()),
    );
  });

  test('the refusal tells the reader what to do about it', () async {
    try {
      await install('some-other-model-v9');
      fail('should have thrown');
    } on PackException catch (e) {
      expect(e.toString(), contains('Update the app'));
    }
  });

  test('a manifest naming this build\'s model is not refused for that reason',
      () async {
    // It still fails — there is no server here to download from — but not with
    // the compatibility message, which is what this is checking.
    try {
      await install(DatabaseService.embeddingModel);
    } catch (e) {
      expect(e.toString(), isNot(contains('Update the app')));
    }
  });

  test('a catalogue with no embedding model at all is still trusted', () async {
    // Older catalogues predate the field, and predate any model change with it.
    try {
      await install(null);
    } catch (e) {
      expect(e.toString(), isNot(contains('Update the app')));
    }
  });

  test('the guard is checked before anything is downloaded', () async {
    // No client was given to this PackService, so reaching the network at all
    // would be a different error than the one expected.
    await expectLater(install('mismatched'), throwsA(isA<PackException>()));
    final rows = await corpus.query('installed_fragments');
    expect(rows, isEmpty);
  });
}

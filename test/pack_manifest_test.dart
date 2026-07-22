import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parsing the published manifest, and the arithmetic the library screen shows.
///
/// Pure, so it lives in the unit suite; the rest of the machinery touches the
/// filesystem, the network and a native database and lives in
/// `integration_test/pack_test.dart`.
void main() {
  const body = '''
  {
    "corpusVersion": 5,
    "fragments": [
      {"id": "f-augustine", "file": "f-augustine.db.gz", "bytes": 4194304,
       "sha256": "aa", "sources": 44, "units": 2496, "chunks": 7179},
      {"id": "f-chrysostom", "file": "f-chrysostom.db.gz", "bytes": 6291456,
       "sha256": "bb", "sources": 36, "units": 2932, "chunks": 9704}
    ],
    "collections": [
      {"id": "author-augustine", "kind": "author", "name": "Augustine of Hippo",
       "description": "The complete Augustine.", "fragments": ["f-augustine"]},
      {"id": "nicene", "kind": "era", "name": "Nicene Writers",
       "description": "", "fragments": ["f-augustine", "f-chrysostom"]}
    ]
  }
  ''';

  test('reads fragments, collections and the corpus version', () {
    final manifest = PackManifest.parse(body);

    expect(manifest.corpusVersion, 5);
    expect(manifest.fragments, hasLength(2));
    expect(manifest.collections, hasLength(2));
    expect(manifest.collections.first.kind, CollectionKind.author);
    expect(manifest.fragment('f-augustine')!.units, 2496);
  });

  group('what a collection costs', () {
    final manifest = PackManifest.parse(body);
    final nicene = manifest.collections.firstWhere((c) => c.id == 'nicene');

    test('everything, when nothing is installed', () {
      expect(manifest.bytesToInstall(nicene, {}), 4194304 + 6291456);
      expect(formatBytes(manifest.bytesToInstall(nicene, {})), '10.0 MB');
    });

    test('only the missing fragment, when one is already held', () {
      // The whole reason fragments exist: a reader who already has Augustine
      // must not be quoted — or charged — for him a second time.
      expect(manifest.bytesToInstall(nicene, {'f-augustine'}), 6291456);
    });

    test('nothing at all, when the collection is already covered', () {
      expect(
        manifest.bytesToInstall(nicene, {'f-augustine', 'f-chrysostom'}),
        0,
      );
    });

    test('an unknown fragment contributes nothing rather than throwing', () {
      // An older app reading a newer manifest should degrade, not crash.
      final stale = PackManifest(
        corpusVersion: 5,
        fragments: manifest.fragments,
        collections: [
          const Collection(id: 'x', name: 'X', description: '',
              kind: CollectionKind.other, fragments: ['f-augustine', 'f-new'])
        ],
      );
      expect(stale.bytesToInstall(stale.collections.single, {}), 4194304);
    });
  });

  test('a malformed manifest throws rather than yielding an empty catalogue',
      () {
    // Returning nothing would render as "no content is published yet", which
    // is indistinguishable from a healthy empty library.
    expect(() => PackManifest.parse('not json'), throwsA(isA<Object>()));
    expect(() => PackManifest.parse('{"fragments": []}'),
        throwsA(isA<Object>()));
  });
}

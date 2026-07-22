import 'package:council/src/services/packs/pack_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parsing the published manifest.
///
/// Kept in the unit suite because it is pure: the rest of the pack machinery
/// touches the filesystem, the network and a native database, and lives in
/// `integration_test/pack_test.dart`.
void main() {
  const body = '''
  {
    "corpusVersion": 3,
    "packs": [
      {
        "id": "fathers-augustine",
        "name": "Augustine of Hippo",
        "description": "The complete Augustine.",
        "file": "fathers-augustine.db.gz",
        "bytes": 4828753,
        "sha256": "47c377c002b55f556c1dfa4fb7d280c02e00da740287a757ecd7866ee9e64c8f",
        "sources": 44,
        "units": 2496,
        "chunks": 7179
      }
    ]
  }
  ''';

  test('reads the corpus version and the packs', () {
    final manifest = PackManifest.parse(body);

    expect(manifest.corpusVersion, 3);
    expect(manifest.packs, hasLength(1));
    expect(manifest.packs.single.id, 'fathers-augustine');
    expect(manifest.packs.single.units, 2496);
  });

  test('sizes are rendered for a human deciding whether to download', () {
    final manifest = PackManifest.parse(body);
    expect(manifest.packs.single.sizeLabel, '4.6 MB');
  });

  test('a pack with no optional fields still parses', () {
    // The manifest is generated, but it is also *published* — an older app
    // reading a newer manifest should not crash over a missing description.
    final manifest = PackManifest.parse('''
      {"corpusVersion": 3, "packs": [{
        "id": "x", "name": "X", "file": "x.db.gz",
        "bytes": 1024, "sha256": "abc"
      }]}
    ''');

    expect(manifest.packs.single.description, isEmpty);
    expect(manifest.packs.single.units, 0);
    expect(manifest.packs.single.sizeLabel, '1 KB');
  });

  test('a malformed manifest throws rather than yielding an empty list', () {
    // Returning nothing would render as "no content is published yet", which
    // is indistinguishable from a healthy empty catalogue.
    expect(() => PackManifest.parse('not json'), throwsA(isA<Object>()));
    expect(() => PackManifest.parse('{"packs": []}'), throwsA(isA<Object>()));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'pack_manifest.dart';

/// Downloads content packs and merges them into the app's database.
///
/// Packs exist because the corpus dwarfs the app: of the 58.8 million
/// characters shipped, 56.3 million are patristic, so a reader who only wants
/// their own tradition's confessions was downloading the complete works of
/// Chrysostom to get them. Splitting the corpus takes the bundled database
/// from 54 MB to 2.6 MB.
///
/// Installing is a merge, not a swap: a pack's rows keep the ids they were
/// assigned in the corpus build they were split from, so they can be inserted
/// straight into the app's tables without renumbering. That is only sound
/// while pack and app come from the same build, which is what [corpusVersion]
/// is checked against.
class PackService {
  /// Where the published packs live.
  ///
  /// GitHub Releases, because packs need static file hosting rather than a
  /// backend: it is free, CDN-backed, versioned, and needs no server to
  /// operate. Nothing here requires the Flutter web target that was dropped.
  static const String defaultManifestUrl =
      'https://github.com/SpencerSmithSite/council/releases/latest/download/manifest.json';

  final Database db;
  final http.Client _client;

  /// Overridable so tests can serve real pack files from a local server and
  /// exercise download, checksum and merge together. A merge tested in
  /// isolation would not catch a pack that downloads correctly and is indexed
  /// wrongly, which is the failure that matters here.
  final String manifestUrl;

  /// Invoked after content is added or removed.
  ///
  /// Semantic search holds the vectors in memory as a snapshot taken at
  /// startup, so without this a newly installed pack is found by lexical
  /// search and ignored by semantic search — which looks like a successful
  /// install with quietly worse answers, the hardest kind of bug to notice.
  final Future<void> Function()? onContentChanged;

  PackService(
    this.db, {
    http.Client? client,
    this.manifestUrl = defaultManifestUrl,
    this.onContentChanged,
  }) : _client = client ?? http.Client();

  /// Bookkeeping for installed packs, kept in the app's database so it cannot
  /// drift from the content it describes.
  ///
  /// [packSources] records which sources arrived with which pack. Without it,
  /// uninstalling means guessing — and the obvious guess, "everything in this
  /// tradition", would delete core content that happens to share a tradition.
  static Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS installed_packs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        corpus_version INTEGER NOT NULL,
        bytes INTEGER NOT NULL,
        units INTEGER NOT NULL,
        installed_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pack_sources (
        pack_id TEXT NOT NULL,
        source_id INTEGER NOT NULL,
        PRIMARY KEY (pack_id, source_id)
      )
    ''');
  }

  Future<Set<String>> installedIds() async {
    final rows = await db.query('installed_packs', columns: ['id']);
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// Fetch the published manifest.
  Future<PackManifest> fetchManifest() async {
    final response = await _client.get(Uri.parse(manifestUrl));
    if (response.statusCode != 200) {
      throw PackException(
          'Could not reach the pack list (HTTP ${response.statusCode}).');
    }
    return PackManifest.parse(utf8.decode(response.bodyBytes));
  }

  /// Download, verify and install [pack].
  ///
  /// [onProgress] reports bytes received against [PackInfo.bytes]; a 24 MB
  /// download with no feedback reads as a hang.
  Future<void> install(
    PackInfo pack, {
    required int corpusVersion,
    required int manifestCorpusVersion,
    void Function(int received, int total)? onProgress,
  }) async {
    if (manifestCorpusVersion != corpusVersion) {
      throw const PackException(
        'This pack was built for a different version of the library. Update '
        'the app and try again.',
      );
    }
    if ((await installedIds()).contains(pack.id)) return;

    final dir = await getApplicationSupportDirectory();
    final workspace = Directory(p.join(dir.path, 'packs'));
    await workspace.create(recursive: true);

    final archive = File(p.join(workspace.path, pack.file));
    final expanded = File(p.join(workspace.path, '${pack.id}.db'));

    try {
      await _download(pack, archive, onProgress);
      await _verify(pack, archive);
      await _expand(archive, expanded);
      await _merge(pack, expanded, corpusVersion);
      await onContentChanged?.call();
    } finally {
      // Whether or not it worked: these are large, and a failed install that
      // leaves 100 MB of temporary files behind is its own bug.
      if (await archive.exists()) await archive.delete();
      if (await expanded.exists()) await expanded.delete();
    }
  }

  Future<void> _download(
    PackInfo pack,
    File destination,
    void Function(int, int)? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(_urlFor(pack)));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw PackException('Download failed (HTTP ${response.statusCode}).');
    }

    // Streamed to disk rather than buffered: the largest pack is 24 MB
    // compressed, and holding it in memory on a phone to then hold the
    // expanded copy as well is avoidable.
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, pack.bytes);
      }
    } finally {
      await sink.close();
    }
  }

  String _urlFor(PackInfo pack) =>
      manifestUrl.replaceFirst('manifest.json', pack.file);

  /// Reject anything whose bytes do not match the manifest.
  ///
  /// A pack is a database that will be merged into the user's library, so a
  /// truncated download is not merely useless — it is a partially-valid
  /// SQLite file that could be merged and leave the library subtly wrong.
  Future<void> _verify(PackInfo pack, File archive) async {
    final digest = await sha256.bind(archive.openRead()).first;
    if (digest.toString() != pack.sha256) {
      throw const PackException(
        'The download did not match its checksum and was discarded. Check '
        'your connection and try again.',
      );
    }
  }

  Future<void> _expand(File archive, File destination) async {
    final sink = destination.openWrite();
    try {
      await sink.addStream(archive.openRead().transform(gzip.decoder));
    } finally {
      await sink.close();
    }
  }

  /// Copy the pack's rows into the app's database and index its text.
  Future<void> _merge(PackInfo pack, File expanded, int corpusVersion) async {
    // ATTACH cannot run inside a transaction, so it brackets one.
    await db.execute("ATTACH DATABASE ? AS pack", [expanded.path]);
    try {
      await db.transaction((txn) async {
        // Reference rows legitimately overlap with what is already installed —
        // every pack carries the full tradition and tag vocabulary so that no
        // source can arrive pointing at a tradition the app has never seen.
        for (final table in const [
          'traditions',
          'source_types',
          'tags',
          'authors',
          'works',
        ]) {
          await txn.execute(
              'INSERT OR IGNORE INTO $table SELECT * FROM pack.$table');
        }

        // Content rows deliberately do *not* use OR IGNORE. Ids are disjoint
        // by construction, so a collision means the pack and the app disagree
        // about the corpus — which should fail loudly here rather than
        // silently drop half the pack and report success.
        for (final table in const [
          'sources',
          'content_units',
          'content_tags',
          'content_chunks',
          'chunk_embeddings',
        ]) {
          await txn.execute('INSERT INTO $table SELECT * FROM pack.$table');
        }

        // Append to the existing index rather than rebuilding it. The column
        // list must match the FTS declaration order (content, title).
        await txn.execute('''
          INSERT INTO content_fts(rowid, content, title)
          SELECT id, content, title FROM pack.content_units
        ''');

        await txn.execute('''
          INSERT INTO pack_sources(pack_id, source_id)
          SELECT ?, id FROM pack.sources
        ''', [pack.id]);

        await txn.insert('installed_packs', {
          'id': pack.id,
          'name': pack.name,
          'corpus_version': corpusVersion,
          'bytes': pack.bytes,
          'units': pack.units,
          'installed_at': DateTime.now().toIso8601String(),
        });
      });
    } finally {
      await db.execute('DETACH DATABASE pack');
    }
  }

  /// Remove an installed pack's content.
  Future<void> uninstall(String packId) async {
    await db.transaction((txn) async {
      const scope = '(SELECT source_id FROM pack_sources WHERE pack_id = ?)';

      await txn.execute('''
        DELETE FROM chunk_embeddings WHERE chunk_id IN (
          SELECT c.id FROM content_chunks c
          JOIN content_units u ON c.content_unit_id = u.id
          WHERE u.source_id IN $scope)
      ''', [packId]);
      await txn.execute('''
        DELETE FROM content_chunks WHERE content_unit_id IN (
          SELECT id FROM content_units WHERE source_id IN $scope)
      ''', [packId]);
      await txn.execute('''
        DELETE FROM content_tags WHERE content_unit_id IN (
          SELECT id FROM content_units WHERE source_id IN $scope)
      ''', [packId]);
      await txn.execute(
          'DELETE FROM content_units WHERE source_id IN $scope', [packId]);
      await txn.execute('DELETE FROM sources WHERE id IN $scope', [packId]);

      // External-content FTS5 has no sync triggers, so deleting the underlying
      // rows leaves the index pointing at text that is gone: searches return
      // matches that cannot be opened. The index is rebuilt rather than
      // patched with 'delete' commands, because those require passing the
      // exact original column values back and corrupt the index silently if
      // they do not match.
      await txn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')");

      await txn.delete('pack_sources', where: 'pack_id = ?', whereArgs: [packId]);
      await txn.delete('installed_packs', where: 'id = ?', whereArgs: [packId]);
    });
    await onContentChanged?.call();
  }

  void dispose() => _client.close();
}

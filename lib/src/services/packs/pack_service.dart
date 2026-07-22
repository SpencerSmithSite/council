import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'pack_manifest.dart';

/// Downloads content and merges it into the app's database.
///
/// Two layers, because the reader and the file system want different things.
/// The reader wants overlapping ways to find text — by author, by era, by
/// tradition — and the same work belongs to several of them. The file system
/// wants each body of text published and stored exactly once.
///
/// So **fragments** are the unit that is downloaded, stored and reference
/// counted, and **collections** are lists of fragment ids. Installing a
/// collection fetches the fragments not already present; removing one drops
/// only the fragments no other installed collection still needs. Nothing is
/// ever downloaded or deleted twice, and adding a new way to browse costs no
/// bytes at all.
class PackService {
  /// Where the published manifest and fragments live.
  ///
  /// GitHub Releases: static file hosting, free, CDN-backed and versioned,
  /// which is all this needs. No backend, and nothing requiring the Flutter
  /// web target that was dropped.
  static const String defaultManifestUrl =
      'https://github.com/SpencerSmithSite/council/releases/latest/download/manifest.json';

  final Database db;
  final http.Client _client;

  /// Overridable so tests can serve real fragments from a local server and
  /// exercise download, checksum and merge together.
  final String manifestUrl;

  /// Invoked after content is added or removed.
  ///
  /// Semantic search holds the vectors in memory as a snapshot taken at
  /// startup, so without this newly installed text is found by lexical search
  /// and ignored by semantic search — an install that looks successful with
  /// quietly worse answers.
  final Future<void> Function()? onContentChanged;

  PackService(
    this.db, {
    http.Client? client,
    this.manifestUrl = defaultManifestUrl,
    this.onContentChanged,
  }) : _client = client ?? http.Client();

  /// Bookkeeping, kept in the app's database so it cannot drift from the
  /// content it describes.
  ///
  /// [collectionFragments] records what each installed collection required, at
  /// the time it was installed. It duplicates the manifest deliberately:
  /// removing a collection has to work out which fragments are still needed by
  /// the others, and that must not depend on being online — nor on the
  /// published manifest still saying what it said last month.
  static Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS installed_collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        corpus_version INTEGER NOT NULL,
        installed_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collection_fragments (
        collection_id TEXT NOT NULL,
        fragment_id TEXT NOT NULL,
        PRIMARY KEY (collection_id, fragment_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS installed_fragments (
        id TEXT PRIMARY KEY,
        bytes INTEGER NOT NULL,
        units INTEGER NOT NULL,
        installed_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS fragment_sources (
        fragment_id TEXT NOT NULL,
        source_id INTEGER NOT NULL,
        PRIMARY KEY (fragment_id, source_id)
      )
    ''');
  }

  Future<Set<String>> installedCollections() async {
    final rows = await db.query('installed_collections', columns: ['id']);
    return rows.map((r) => r['id'] as String).toSet();
  }

  Future<Set<String>> installedFragments() async {
    final rows = await db.query('installed_fragments', columns: ['id']);
    return rows.map((r) => r['id'] as String).toSet();
  }

  Future<PackManifest> fetchManifest() async {
    final response = await _client.get(Uri.parse(manifestUrl));
    if (response.statusCode != 200) {
      throw PackException(
          'Could not reach the library catalogue (HTTP ${response.statusCode}).');
    }
    return PackManifest.parse(utf8.decode(response.bodyBytes));
  }

  /// Install every fragment [collection] needs that is not already present.
  ///
  /// [onProgress] reports across the whole operation rather than per fragment,
  /// since the reader chose a collection and does not know fragments exist.
  Future<void> install(
    Collection collection,
    PackManifest manifest, {
    required int corpusVersion,
    void Function(int received, int total)? onProgress,
  }) async {
    if (manifest.corpusVersion != corpusVersion) {
      throw const PackException(
        'This content was built for a different version of the app. Update '
        'the app and try again.',
      );
    }

    final present = await installedFragments();
    final wanted = collection.fragments
        .where((id) => !present.contains(id))
        .map((id) => manifest.fragment(id))
        .whereType<Fragment>()
        .toList();

    final total = wanted.fold(0, (sum, f) => sum + f.bytes);
    var done = 0;

    for (final fragment in wanted) {
      await _installFragment(
        fragment,
        onProgress: (received, _) => onProgress?.call(done + received, total),
      );
      done += fragment.bytes;
    }

    // Recorded even when every fragment was already present: the collection is
    // what the reader chose, and it has to be removable later.
    await db.insert(
      'installed_collections',
      {
        'id': collection.id,
        'name': collection.name,
        'corpus_version': corpusVersion,
        'installed_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final id in collection.fragments) {
      await db.insert(
        'collection_fragments',
        {'collection_id': collection.id, 'fragment_id': id},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    if (wanted.isNotEmpty) await onContentChanged?.call();
  }

  Future<void> _installFragment(
    Fragment fragment, {
    void Function(int, int)? onProgress,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final workspace = Directory(p.join(dir.path, 'packs'));
    await workspace.create(recursive: true);

    final archive = File(p.join(workspace.path, fragment.file));
    final expanded = File(p.join(workspace.path, '${fragment.id}.db'));

    try {
      await _download(fragment, archive, onProgress);
      await _verify(fragment, archive);
      await _expand(archive, expanded);
      await _merge(fragment, expanded);
    } finally {
      // Whether or not it worked: a failed install that leaves 100 MB of
      // temporary files behind is its own bug.
      if (await archive.exists()) await archive.delete();
      if (await expanded.exists()) await expanded.delete();
    }
  }

  Future<void> _download(
    Fragment fragment,
    File destination,
    void Function(int, int)? onProgress,
  ) async {
    final url = manifestUrl.replaceFirst('manifest.json', fragment.file);
    final response = await _client.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw PackException('Download failed (HTTP ${response.statusCode}).');
    }

    // Streamed to disk rather than buffered: holding a fragment in memory and
    // then its expanded copy as well is avoidable on a phone.
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, fragment.bytes);
      }
    } finally {
      await sink.close();
    }
  }

  /// Reject anything whose bytes do not match the manifest.
  ///
  /// A fragment is a database about to be merged into the reader's library, so
  /// a truncated download is not merely useless — it is a partially valid
  /// SQLite file that could merge and leave the library subtly wrong.
  Future<void> _verify(Fragment fragment, File archive) async {
    final digest = await sha256.bind(archive.openRead()).first;
    if (digest.toString() != fragment.sha256) {
      throw const PackException(
        'A download did not match its checksum and was discarded. Check your '
        'connection and try again.',
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

  Future<void> _merge(Fragment fragment, File expanded) async {
    // ATTACH cannot run inside a transaction, so it brackets one.
    await db.execute("ATTACH DATABASE ? AS pack", [expanded.path]);
    try {
      await db.transaction((txn) async {
        // Reference rows legitimately overlap — every fragment carries the
        // full tradition and tag vocabulary, so no source can arrive pointing
        // at a tradition the app has never seen.
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

        // Content rows deliberately do *not* use OR IGNORE. Fragments are a
        // partition, so their ids are disjoint and a collision means the
        // fragment and the app disagree about the corpus — which should fail
        // loudly rather than silently drop half of it and report success.
        for (final table in const [
          'sources',
          'content_units',
          'content_tags',
          'content_chunks',
          'chunk_embeddings',
        ]) {
          await txn.execute('INSERT INTO $table SELECT * FROM pack.$table');
        }

        // Appended to the existing index rather than rebuilding it. The column
        // list must match the FTS declaration order (content, title).
        await txn.execute('''
          INSERT INTO content_fts(rowid, content, title)
          SELECT id, content, title FROM pack.content_units
        ''');

        await txn.execute('''
          INSERT INTO fragment_sources(fragment_id, source_id)
          SELECT ?, id FROM pack.sources
        ''', [fragment.id]);

        await txn.insert('installed_fragments', {
          'id': fragment.id,
          'bytes': fragment.bytes,
          'units': fragment.units,
          'installed_at': DateTime.now().toIso8601String(),
        });
      });
    } finally {
      await db.execute('DETACH DATABASE pack');
    }
  }

  /// Remove a collection, keeping any fragment another collection still needs.
  ///
  /// This is the whole reason fragments exist as a separate layer. Someone with
  /// both "Church Fathers" and "Augustine of Hippo" who removes the former must
  /// keep Augustine; someone who removes the latter must keep everything, since
  /// Church Fathers needs it too.
  Future<void> uninstall(String collectionId) async {
    final ownFragments = (await db.query(
      'collection_fragments',
      columns: ['fragment_id'],
      where: 'collection_id = ?',
      whereArgs: [collectionId],
    ))
        .map((r) => r['fragment_id'] as String)
        .toSet();

    // What the *other* installed collections still require. Read from the
    // local record rather than the manifest, so this works offline and cannot
    // be changed underneath the reader by a new publication.
    final stillNeeded = (await db.rawQuery('''
      SELECT DISTINCT cf.fragment_id FROM collection_fragments cf
      JOIN installed_collections ic ON ic.id = cf.collection_id
      WHERE cf.collection_id != ?
    ''', [collectionId]))
        .map((r) => r['fragment_id'] as String)
        .toSet();

    final doomed = ownFragments.difference(stillNeeded);
    final present = await installedFragments();

    await db.transaction((txn) async {
      for (final fragment in doomed) {
        if (!present.contains(fragment)) continue;
        await _deleteFragment(txn, fragment);
      }

      if (doomed.isNotEmpty) {
        // External-content FTS5 has no sync triggers, so deleting the rows
        // leaves the index pointing at text that is gone and searches return
        // matches that cannot be opened. The index is rebuilt rather than
        // patched with 'delete' commands, which require passing the exact
        // original column values back and corrupt the index silently when
        // they do not match.
        await txn.execute(
            "INSERT INTO content_fts(content_fts) VALUES('rebuild')");
      }

      await txn.delete('collection_fragments',
          where: 'collection_id = ?', whereArgs: [collectionId]);
      await txn.delete('installed_collections',
          where: 'id = ?', whereArgs: [collectionId]);
    });

    if (doomed.isNotEmpty) await onContentChanged?.call();
  }

  Future<void> _deleteFragment(Transaction txn, String fragmentId) async {
    const scope = '(SELECT source_id FROM fragment_sources WHERE fragment_id = ?)';

    await txn.execute('''
      DELETE FROM chunk_embeddings WHERE chunk_id IN (
        SELECT c.id FROM content_chunks c
        JOIN content_units u ON c.content_unit_id = u.id
        WHERE u.source_id IN $scope)
    ''', [fragmentId]);
    await txn.execute('''
      DELETE FROM content_chunks WHERE content_unit_id IN (
        SELECT id FROM content_units WHERE source_id IN $scope)
    ''', [fragmentId]);
    await txn.execute('''
      DELETE FROM content_tags WHERE content_unit_id IN (
        SELECT id FROM content_units WHERE source_id IN $scope)
    ''', [fragmentId]);
    await txn.execute(
        'DELETE FROM content_units WHERE source_id IN $scope', [fragmentId]);
    await txn.execute('DELETE FROM sources WHERE id IN $scope', [fragmentId]);

    await txn.delete('fragment_sources',
        where: 'fragment_id = ?', whereArgs: [fragmentId]);
    await txn.delete('installed_fragments',
        where: 'id = ?', whereArgs: [fragmentId]);
  }

  void dispose() => _client.close();
}

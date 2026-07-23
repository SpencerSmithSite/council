import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'search/entity_recogniser.dart';
import 'search/hybrid_ranker.dart';
import 'search/semantic_search.dart';
import 'packs/pack_service.dart';

class DatabaseService {
  /// Optional semantic retrieval. Injected rather than constructed here so the
  /// unit suite never pulls in the native plugin, and so an app on a device
  /// that cannot run the model degrades to lexical search instead of failing.
  SemanticSearch? semantic;

  /// Lazily built on first scoped search — it reads every source row, which is
  /// wasted work for a session that never asks a scoped question.
  EntityRecogniser? _recogniser;

  Future<EntityRecogniser> get recogniser async =>
      _recogniser ??= await EntityRecogniser.load(database);

  /// Bumped when the bundled corpus changes, so an installed copy of an older
  /// database is replaced rather than kept forever.
  ///
  /// It also gates content packs. A pack keeps the row ids it was given in the
  /// corpus build it was split from — that is what lets it be merged without
  /// renumbering — so a pack from a different build can carry ids this app has
  /// already used for different text. Packs declare the version they were built
  /// from and are refused when it does not match this one.
  static const int corpusVersion = 11;

  Database? _database;

  /// Initialize database from bundled asset
  Future<void> initialize() async {
    // A path_provider directory rather than sqflite's getDatabasesPath(): under
    // the FFI factory (used so a bundled FTS5-enabled SQLite is available on
    // every platform) getDatabasesPath() is not a reliable writable location on
    // Android, whereas the application-support directory always is.
    final databasesPath = (await getApplicationSupportDirectory()).path;
    final dbPath = p.join(databasesPath, 'theology.db');
    final stampPath = p.join(databasesPath, 'theology.corpus-version');

    // Reinstall when absent or stale. Without the version check, users who
    // already ran the app would keep the old corpus forever.
    final stamp = File(stampPath);
    final installedVersion =
        await stamp.exists() ? int.tryParse(await stamp.readAsString()) : null;

    if (!await File(dbPath).exists() || installedVersion != corpusVersion) {
      await _reinstall(dbPath, stamp);
    }

    // Writable, unlike every earlier version of this app. Content packs merge
    // downloaded sources into these same tables, so the corpus is no longer
    // purely a read-only shipped artefact.
    _database = await openDatabase(dbPath);
    await PackService.createTables(_database!);
  }

  /// Reinstalling the bundled corpus discards any packs the user downloaded.
  ///
  /// The stamp is written *after* the copy so that a crash midway leaves the
  /// app looking un-installed and retrying, rather than looking current while
  /// holding a half-written database.
  Future<void> _reinstall(String dbPath, File stamp) async {
    await _copyDatabaseFromAsset(dbPath);
    await stamp.writeAsString('$corpusVersion');
  }

  /// Unpack the bundled database into device storage.
  ///
  /// The asset ships gzipped: the corpus is ~95 MB of patristic text, which
  /// compresses to ~39 MB. That keeps the download and the repository within
  /// sane limits at the cost of a one-off decompression on first launch.
  Future<void> _copyDatabaseFromAsset(String dbPath) async {
    // Create parent directory if needed
    final parent = p.dirname(dbPath);
    await Directory(parent).create(recursive: true);

    final data = await rootBundle.load('assets/theology.db.gz');
    final compressed = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final bytes = gzip.decode(compressed);
    await File(dbPath).writeAsBytes(bytes, flush: true);
  }
  
  /// Get database instance
  Database get database {
    if (_database == null) {
      throw StateError('Database not initialized. Call initialize() first.');
    }
    return _database!;
  }
  
  /// Build an FTS5 MATCH expression from natural-language input.
  ///
  /// Terms are joined with OR, not juxtaposed. FTS5 reads "a b" as an implicit
  /// AND, so a question phrased as a sentence required *every* word — "what",
  /// "did", "the" included — to appear in a single passage. Against the real
  /// index that matched **zero** units for "What did the Council of Trent
  /// decree about justification?", where the OR form matches 1,423. Ranking
  /// already rewards passages containing more of the rarer terms, so OR gives
  /// up nothing in precision.
  ///
  /// Short words are dropped for the same reason: noise in the match, nothing
  /// in the ranking.
  static String ftsMatchQuery(String query) {
    final terms = query
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 2)
        .map((t) => '$t*');
    return terms.join(' OR ');
  }

  /// Search content with FTS5 full-text search
  Future<List<Map<String, dynamic>>> search(String query, {int limit = 20}) async {
    final ftsTerms = ftsMatchQuery(query);
    if (ftsTerms.isEmpty) return _searchLike(query, limit: limit);

    final results = await database.rawQuery('''
      SELECT $_contentUnitColumns, fts.rank
      FROM content_fts fts
      JOIN content_units cu ON fts.rowid = cu.id
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE content_fts MATCH ?
      ORDER BY fts.rank
      LIMIT ?
    ''', [ftsTerms, limit]);
    
    // If FTS5 returns no results, fall back to LIKE search
    if (results.isEmpty) {
      return await _searchLike(query, limit: limit);
    }
    
    return results;
  }
  
  /// Fallback LIKE search
  Future<List<Map<String, dynamic>>> _searchLike(String query, {int limit = 20}) async {
    final results = await database.rawQuery('''
      SELECT $_contentUnitColumns
      FROM content_units cu
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE cu.content LIKE ?
      ORDER BY cu.sequence
      LIMIT ?
    ''', ['%$query%', limit]);
    
    return results;
  }
  
  /// Search by tags for better RAG retrieval
  Future<List<Map<String, dynamic>>> searchByTags(List<String> tags, {int limit = 20}) async {
    final placeholders = tags.map((_) => '?').join(',');
    final results = await database.rawQuery('''
      SELECT $_contentUnitColumns, COUNT(ct.tag_id) as tag_matches
      FROM content_units cu
      JOIN content_tags ct ON cu.id = ct.content_unit_id
      JOIN tags tg ON ct.tag_id = tg.id
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE tg.slug IN ($placeholders)
      GROUP BY cu.id
      ORDER BY tag_matches DESC
      LIMIT ?
    ''', [...tags.map((t) => t.toLowerCase().replaceAll(' ', '-')), limit]);
    
    return results;
  }
  
  /// Guarantee that every tradition the question named is actually present.
  ///
  /// Only acts when the question named more than one — a question about a
  /// single tradition should be answered from it, and one that named none has
  /// no comparison to balance.
  Future<List<Map<String, dynamic>>> _ensureNamedTraditions(
    String query,
    RecognisedEntities scope,
    List<Map<String, dynamic>> selected,
    int limit,
  ) async {
    if (scope.traditionIds.length < 2) return selected;

    final names = await _traditionNames(scope.traditionIds);
    final present = selected.map((r) => r['tradition'] as String?).toSet();
    final missing = names.entries.where((e) => !present.contains(e.value));
    if (missing.isEmpty) return selected;

    final result = [...selected];
    for (final entry in missing) {
      final rows = await _searchScoped(
        query,
        RecognisedEntities(traditionIds: {entry.key}),
        limit: 2,
      );
      if (rows.isEmpty) continue;

      // Displace the lowest-ranked passage from whichever tradition is most
      // over-represented, so the comparison gains a voice without the answer
      // growing or a thinly-represented tradition losing its only one.
      final counts = <String?, int>{};
      for (final row in result) {
        final t = row['tradition'] as String?;
        counts[t] = (counts[t] ?? 0) + 1;
      }
      final crowded = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;

      final victim = result.lastIndexWhere((r) => r['tradition'] == crowded);
      if (result.length >= limit && victim >= 0) {
        result[victim] = rows.first;
      } else if (result.length < limit) {
        result.add(rows.first);
      }
    }
    return result;
  }

  Future<Map<int, String>> _traditionNames(Set<int> ids) async {
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await database.rawQuery(
      'SELECT id, name FROM traditions WHERE id IN ($marks)', ids.toList());
    return {
      for (final row in rows) row['id'] as int: row['name'] as String,
    };
  }

  /// FTS5 search restricted to particular sources or traditions.
  Future<List<Map<String, dynamic>>> _searchScoped(
    String query,
    RecognisedEntities scope, {
    int limit = 20,
  }) async {
    final ftsTerms = ftsMatchQuery(query);
    if (ftsTerms.isEmpty) return const [];

    final clauses = <String>[];
    final args = <Object?>[ftsTerms];

    if (scope.sourceIds.isNotEmpty) {
      final marks = List.filled(scope.sourceIds.length, '?').join(',');
      clauses.add('s.id IN ($marks)');
      args.addAll(scope.sourceIds);
    }
    if (scope.traditionIds.isNotEmpty) {
      final marks = List.filled(scope.traditionIds.length, '?').join(',');
      clauses.add('s.tradition_id IN ($marks)');
      args.addAll(scope.traditionIds);
    }
    args.add(limit);

    // Sources OR traditions: naming both ("what does the Belgic Confession
    // say, and Reformed teaching generally") should widen the scope, not
    // demand a passage satisfy both at once.
    final scopeClause = clauses.join(' OR ');

    return database.rawQuery('''
      SELECT $_contentUnitColumns, fts.rank
      FROM content_fts fts
      JOIN content_units cu ON fts.rowid = cu.id
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE content_fts MATCH ?
        AND ($scopeClause)
      ORDER BY fts.rank
      LIMIT ?
    ''', args);
  }

  /// Combined search: FTS5 + tag-based for best RAG results
  Future<List<Map<String, dynamic>>> searchForRAG(String query, {int limit = 5}) async {
    // When a question names an author, work or tradition, that is a constraint
    // rather than another term to match. Without this, "what did Aquinas say
    // about Mary?" ranks passages about Mary by whoever wrote most about her,
    // and a question about the Council of Trent returns Carthage and Nicaea.
    final scope = (await recogniser).recognise(query);

    List<Map<String, dynamic>> ftsResults;
    if (scope.isNotEmpty) {
      ftsResults = await _searchScoped(query, scope, limit: limit * 4);
      // A scope the corpus can barely satisfy should narrow the answer, not
      // empty it — fall back rather than returning nothing.
      if (ftsResults.length < 2) {
        ftsResults = await search(query, limit: limit * 2);
      }
    } else {
      ftsResults = await search(query, limit: limit * 2);
    }
    
    // Extract potential tags from query
    final queryTags = extractTags(query);
    
    // Get tag-based results if we have tags
    List<Map<String, dynamic>> tagResults = [];
    if (queryTags.isNotEmpty) {
      tagResults = await searchByTags(queryTags, limit: limit);
    }
    
    // Semantic ranking, when the model is available. This is what lets a
    // question be answered by passages that share its meaning but not its
    // words — "how is a person saved?" against confessional language about
    // justification, which lexical search structurally cannot reach.
    List<int> semanticUnits = const [];
    if (semantic != null) {
      semanticUnits = await semantic!.rankedUnits(
        query,
        limit: limit * 4,
        allowedUnitIds: scope.isNotEmpty ? await _unitsInScope(scope) : null,
      );
    }

    // Fuse the two rankings by reciprocal rank. BM25 and cosine sit on
    // incomparable scales, so rank position is what can be combined without
    // calibrating either distribution.
    final byId = <int, Map<String, dynamic>>{};
    for (final row in [...ftsResults, ...tagResults]) {
      byId.putIfAbsent(row['id'] as int, () => row);
    }

    final missing = semanticUnits.where((id) => !byId.containsKey(id)).toList();
    for (final row in await _unitsByIds(missing)) {
      byId[row['id'] as int] = row;
    }

    final fused = HybridRanker.fuse(
      lexical: [
        for (final row in ftsResults) row['id'] as int,
        for (final row in tagResults) row['id'] as int,
      ],
      semantic: semanticUnits,
      limit: limit * 4,
    );

    final combined = [
      for (final id in fused)
        if (byId[id] != null) byId[id]!,
    ];

    // Spread the results across sources and traditions before truncating.
    // Relevance order alone fills every slot from whichever tradition the
    // corpus happens to hold most of, which for a comparative question is the
    // wrong answer even when each individual passage is relevant.
    final selected = HybridRanker.diversify<Map<String, dynamic>>(
      combined,
      sourceOf: (row) => row['source_title'],
      traditionOf: (row) => row['tradition'],
      limit: limit,
    );

    // A question naming two traditions is asking for a comparison, and an
    // answer drawn entirely from one of them does not answer it. Diversity
    // quotas alone cannot guarantee this: they cap how many slots a tradition
    // may take, but if the other tradition never reaches the candidate pool
    // there is nothing to fill the remainder with, and the backfill hands the
    // slots straight back.
    //
    // This became a live failure rather than a theoretical one when Aquinas
    // was added: 14 million characters of Catholic material against 0.79
    // million Lutheran meant "how do Catholics and Lutherans differ on
    // baptism" returned six Catholic passages and no Lutheran ones.
    final balanced = await _ensureNamedTraditions(query, scope, selected, limit);

    // Replace each unit's full text with the chunk that best matches the
    // query. A unit can be 162 KB; handing the model its first N characters
    // means the relevant passage is usually not in the window at all.
    return [
      for (final row in balanced)
        {...row, 'content': await _bestChunkText(row, query)},
    ];
  }

  /// The content unit ids a recognised scope admits.
  Future<Set<int>> _unitsInScope(RecognisedEntities scope) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (scope.sourceIds.isNotEmpty) {
      clauses.add('s.id IN (${List.filled(scope.sourceIds.length, '?').join(',')})');
      args.addAll(scope.sourceIds);
    }
    if (scope.traditionIds.isNotEmpty) {
      clauses.add(
          's.tradition_id IN (${List.filled(scope.traditionIds.length, '?').join(',')})');
      args.addAll(scope.traditionIds);
    }
    if (clauses.isEmpty) return const {};

    final rows = await database.rawQuery('''
      SELECT cu.id FROM content_units cu
      JOIN sources s ON cu.source_id = s.id
      WHERE ${clauses.join(' OR ')}
    ''', args);
    return {for (final row in rows) row['id'] as int};
  }

  /// Fetch units the semantic ranking found that the lexical pass did not.
  Future<List<Map<String, dynamic>>> _unitsByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    return database.rawQuery('''
      SELECT $_contentUnitColumns
      FROM content_units cu
      LEFT JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE cu.id IN (${List.filled(ids.length, '?').join(',')})
    ''', ids);
  }

  /// Text of the chunk within [row]'s unit that best matches [query].
  ///
  /// Scoring is term overlap, which is crude but adequate: the unit has
  /// already been selected by FTS, so this only has to choose between a
  /// handful of slices of one document. Semantic scoring happens earlier, at
  /// the point units are selected.
  Future<String> _bestChunkText(Map<String, dynamic> row, String query) async {
    final content = row['content'] as String? ?? '';
    final chunks = await database.query(
      'content_chunks',
      columns: ['char_start', 'char_end'],
      where: 'content_unit_id = ?',
      whereArgs: [row['id']],
      orderBy: 'sequence',
    );

    if (chunks.length <= 1) return content;

    final terms = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length > 2)
        .toSet();
    if (terms.isEmpty) return content;

    String? best;
    var bestScore = -1;

    for (final chunk in chunks) {
      final start = chunk['char_start'] as int;
      final end = (chunk['char_end'] as int).clamp(0, content.length);
      if (start >= end) continue;

      final text = content.substring(start, end);
      final lower = text.toLowerCase();

      var score = 0;
      for (final term in terms) {
        if (lower.contains(term)) score++;
      }

      if (score > bestScore) {
        bestScore = score;
        best = text;
      }
    }

    return best ?? content;
  }

  
  /// The complete tag vocabulary present in the bundled database.
  ///
  /// Every slug produced by [extractTags] must appear here — a mapping to a
  /// slug outside this set matches nothing and silently degrades retrieval.
  static const Set<String> tagSlugs = {
    'angels',
    'baptism',
    'christology',
    'church',
    'creation',
    'eschatology',
    'eucharist',
    'faith',
    'grace',
    'holy-spirit',
    'incarnation',
    'justification',
    'last-judgment',
    'prayer',
    'sacraments',
    'salvation',
    'sanctification',
    'scripture',
    'sin',
    'trinity',
    'worship',
  };

  /// Query phrases mapped onto the tag vocabulary.
  ///
  /// Several phrases are technical names for a doctrine the database tags under
  /// a plainer slug (soteriology → salvation, ecclesiology → church), so the
  /// mapping is many-to-many rather than one-to-one.
  static const Map<String, List<String>> _tagSynonyms = {
    'angel': ['angels'],
    'atonement': ['salvation', 'christology'],
    'baptism': ['baptism'],
    'christology': ['christology'],
    'church': ['church'],
    'communion': ['eucharist', 'sacraments'],
    'creation': ['creation'],
    'ecclesiology': ['church'],
    'eschatology': ['eschatology'],
    'eucharist': ['eucharist'],
    'faith': ['faith'],
    'free will': ['grace', 'salvation'],
    'grace': ['grace'],
    'heaven': ['eschatology'],
    'hell': ['eschatology', 'last-judgment'],
    'holiness': ['sanctification'],
    'holy spirit': ['holy-spirit'],
    'incarnation': ['incarnation'],
    'judgment': ['last-judgment'],
    'justification': ['justification'],
    'liturgy': ['worship'],
    'lord\'s supper': ['eucharist', 'sacraments'],
    'mass': ['eucharist'],
    'pneumatology': ['holy-spirit'],
    'prayer': ['prayer'],
    'predestination': ['salvation', 'grace'],
    'resurrection': ['eschatology', 'christology'],
    'sacrament': ['sacraments'],
    'salvation': ['salvation'],
    'sanctification': ['sanctification'],
    'scripture': ['scripture'],
    'second coming': ['eschatology'],
    'sin': ['sin'],
    'soteriology': ['salvation'],
    'trinity': ['trinity'],
    'worship': ['worship'],
  };

  /// [_tagSynonyms] compiled to whole-word patterns, built once.
  ///
  /// Plain substring matching produces nonsense hits — "hello" contains "hell",
  /// "sincere" contains "sin", "evangelical" contains "angel" — so each phrase
  /// is anchored on word boundaries, with an optional plural suffix so "sins"
  /// and "sacraments" still match.
  static final Map<RegExp, List<String>> _tagPatterns = {
    for (final entry in _tagSynonyms.entries)
      RegExp(
        r'\b' + RegExp.escape(entry.key) + r'(s|es)?\b',
        caseSensitive: false,
      ): entry.value,
  };

  /// Extract tag slugs from a query, deduplicated.
  ///
  /// Public rather than test-only because the coverage notice needs the same
  /// reading of the question that retrieval used. Deriving the subject a second
  /// way would let the two disagree — telling someone their Eucharist question
  /// was under-covered while the retriever had decided the question was about
  /// something else.
  List<String> extractTags(String query) {
    final matched = <String>{};

    for (final entry in _tagPatterns.entries) {
      if (entry.key.hasMatch(query)) {
        matched.addAll(entry.value);
      }
    }

    return matched.toList();
  }
  
  /// Get all traditions
  Future<List<Map<String, dynamic>>> getTraditions() async {
    return await database.query('traditions', orderBy: 'name');
  }
  
  /// Get all source types
  Future<List<Map<String, dynamic>>> getSourceTypes() async {
    return await database.query('source_types', orderBy: 'name');
  }
  
  /// Get sources by tradition
  Future<List<Map<String, dynamic>>> getSourcesByTradition(int traditionId) async {
    return await database.query(
      'sources',
      where: 'tradition_id = ?',
      whereArgs: [traditionId],
      orderBy: 'date_composed',
    );
  }
  
  /// Get sources by type
  Future<List<Map<String, dynamic>>> getSourcesByType(int typeId) async {
    return await database.query(
      'sources',
      where: 'source_type_id = ?',
      whereArgs: [typeId],
      orderBy: 'date_composed',
    );
  }
  
  /// Get content units for a source
  Future<List<Map<String, dynamic>>> getContentForSource(int sourceId) async {
    return await database.query(
      'content_units',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'sequence',
    );
  }
  
  /// Columns shared by every query that returns a content unit with its source.
  ///
  /// Callers rely on `source_title` being present — bookmarks, recently viewed,
  /// and share text all record it.
  /// Everything a citation needs to be checkable.
  ///
  /// Used by *every* retrieval path, which matters more than it looks.
  /// `searchForRAG` fuses results from full-text search, tag search and the
  /// vector index, and each of those used to hand-write its own column list.
  /// The same passage therefore carried different metadata depending on how it
  /// happened to be found — a citation showing its tradition or not according
  /// to which engine surfaced it.
  ///
  /// `source_url` and `license` are here because a citation that names a work
  /// without saying where the text came from cannot be verified — and this
  /// corpus contains both properly-sourced editions and legacy stubs with no
  /// recorded origin. Carrying the field is what lets the UI tell them apart
  /// instead of presenting both with equal confidence.
  static const String _contentUnitColumns = '''
        cu.*,
        s.title as source_title,
        s.author as source_author,
        s.date_composed,
        s.source_url,
        s.license,
        t.name as tradition,
        st.name as source_type
  ''';

  /// Get single content unit, joined to its source.
  ///
  /// LEFT JOIN deliberately: 71 units carry a `source_id` with no matching row
  /// in `sources`, and an inner join would make those passages unopenable.
  /// They surface with a null `source_title` instead.
  Future<Map<String, dynamic>?> getContentUnit(int id) async {
    final results = await database.rawQuery('''
      SELECT $_contentUnitColumns
      FROM content_units cu
      LEFT JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      WHERE cu.id = ?
      LIMIT 1
    ''', [id]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Get a uniformly random content unit, joined to its source.
  ///
  /// Selecting in SQL rather than guessing an id — content unit ids are sparse
  /// (4918 rows spread over ids 1..4933), so a random id can miss.
  Future<Map<String, dynamic>?> getRandomContentUnit() async {
    final results = await database.rawQuery('''
      SELECT $_contentUnitColumns
      FROM content_units cu
      JOIN sources s ON cu.source_id = s.id
      LEFT JOIN traditions t ON s.tradition_id = t.id
      LEFT JOIN source_types st ON s.source_type_id = st.id
      ORDER BY RANDOM()
      LIMIT 1
    ''');
    return results.isNotEmpty ? results.first : null;
  }
  
  /// Get tags for content unit
  Future<List<Map<String, dynamic>>> getTagsForContent(int contentId) async {
    return await database.rawQuery('''
      SELECT t.id, t.name, t.slug, t.category
      FROM tags t
      JOIN content_tags ct ON t.id = ct.tag_id
      WHERE ct.content_unit_id = ?
      ORDER BY t.category, t.name
    ''', [contentId]);
  }
  
  /// Get database statistics
  Future<Map<String, dynamic>> getStats() async {
    final sources = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM sources')
    ) ?? 0;
    
    final content = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM content_units')
    ) ?? 0;
    
    final traditions = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM traditions')
    ) ?? 0;
    
    final tags = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM tags')
    ) ?? 0;
    
    return {
      'sources': sources,
      'content_units': content,
      'traditions': traditions,
      'tags': tags,
    };
  }
  
  /// Close database
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
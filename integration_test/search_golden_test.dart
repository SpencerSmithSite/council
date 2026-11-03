import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/search/hybrid_ranker.dart';
import 'package:council/src/services/search/query_encoder.dart';
import 'package:council/src/services/search/semantic_search.dart';
import 'package:council/src/services/search/vector_index.dart';
import 'package:council/src/services/search/wordpiece_tokenizer.dart';

/// Golden search fixtures: what the Flutter retrieval code returns at every
/// stage, for a fixed query set, against the bundled core corpus.
///
/// The SwiftUI app in `apple/` reimplements retrieval and must return the same
/// results; `shared/golden/search/search.json` is what it is tested against,
/// stage by stage. This test keeps that file honest: by default it asserts the
/// current Dart code reproduces the file, and with UPDATE_GOLDENS it rewrites
/// it. Format and tolerances are in `shared/golden/search/README.md`.
///
/// Run it through the helper, not directly:
///
///     tools/search_goldens.sh            # verify
///     tools/search_goldens.sh --update   # regenerate
///
/// The macOS debug build is sandboxed (macos/Runner/DebugProfile.entitlements),
/// so the test can neither read nor write the repository. The helper serves the
/// fixture to it over loopback HTTP (SEARCH_GOLDEN_URL), and in update mode the
/// test prints the new fixture between markers, gzip+base64 encoded, for the
/// helper to decode back into the file.
///
/// Every stage comes from the real classes. The two stages that live in private
/// methods of [DatabaseService] — the scoped FTS query and the unit set a scope
/// admits — are observed rather than recomputed: the service runs against a
/// [Database] wrapper that records each query and its rows, and its
/// [SemanticSearch] is wrapped to record what it was asked and what it said.
const _update = bool.fromEnvironment('UPDATE_GOLDENS');
const _goldenUrl = String.fromEnvironment('SEARCH_GOLDEN_URL');

/// Absolute tolerance for every floating-point value in the fixture. Ids,
/// orderings, strings and integers compare exactly.
const _tolerance = 1e-5;

/// The limits the app itself calls with: the chat screen's
/// `searchForRAG(text, limit: 6)` and the Read tab's `search(text, limit: 40)`.
const _ragLimit = 6;
const _readLimit = 40;

/// Derived from [_ragLimit] the way `searchForRAG` derives them: it asks
/// semantic search for `limit * 4` units and fuses to `limit * 4`, and
/// `SemanticSearch.rankedUnits` asks the index for `limit * 6` chunks.
const _fusionLimit = _ragLimit * 4;
const _vectorTopLimit = _fusionLimit * 6;

class _Query {
  final String id;
  final String text;
  final String why;
  const _Query(this.id, this.text, this.why);
}

final _queries = <_Query>[
  // Scripture references. Nothing parses them: they go through FTS and the
  // encoder like any other text, and these pin down what that yields.
  const _Query('ref-john-3-16', 'John 3:16',
      'bare verse reference; FTS keeps only "John", digits are dropped'),
  const _Query('ref-rom-8', 'Rom 8',
      'abbreviated book; the "Rom"* prefix term matches the title "Romans"'),
  const _Query('ref-genesis-1-1', 'Genesis 1:1', 'first verse of the corpus'),
  const _Query('ref-1-corinthians-13', '1 Corinthians 13',
      'numbered book; the leading digit is too short for FTS'),
  const _Query('ref-psalm-23', 'Psalm 23',
      'singular "Psalm" against titles reading "Psalms 23"'),

  // Keyword queries.
  const _Query('kw-justification-by-faith', 'justification by faith',
      'doctrinal keyword plus the justification tag'),
  const _Query('kw-baptism', 'baptism', 'single keyword that is also a tag'),
  const _Query('kw-love-your-enemies', 'love your enemies',
      'phrase with a stopword dropped from FTS'),
  const _Query('kw-lamb-of-god', 'lamb of God', 'short phrase, no tags'),
  const _Query('kw-covenant-abraham', 'the covenant with Abraham',
      'proper noun keyword'),

  // Questions whose words are not in the answer: semantic does the work.
  const _Query('sem-person-saved', 'How is a person saved?',
      'the case semantic search exists for (also in retrieval_test.dart)'),
  const _Query('sem-good-people-suffer', 'Why do good people suffer?',
      'theodicy in modern words'),
  const _Query('sem-after-death', 'What happens after we die?',
      'eschatology without its vocabulary'),
  const _Query('sem-anxious-future', 'feeling anxious about tomorrow',
      'pastoral question in modern idiom'),

  // Named entities. The core corpus holds one source (the KJV) and the full
  // traditions table, so only the KJV title and tradition names can match.
  const _Query('ent-kjv-work', 'What does the King James Bible say about grace?',
      'names the one bundled work, so the scope is the whole corpus'),
  const _Query('ent-scripture-tradition', 'Scripture on prayer',
      'names the Scripture tradition; a scope the corpus can satisfy'),
  const _Query('ent-lutheran', 'What do Lutherans believe about baptism?',
      'adjectival tradition; scope admits no core units, so FTS falls back'),
  const _Query('ent-catholic', 'Catholic teaching on the Eucharist',
      '"catholic" is in five tradition names; the shortest, Catholic, wins'),
  const _Query('ent-two-traditions', 'Catholics and Lutherans on justification',
      'two traditions, so _ensureNamedTraditions runs'),
  const _Query('ent-calvinist', 'Calvinist predestination',
      'adjectival alias for Reformed, plus multi-tag synonym'),
  const _Query('ent-early-church', 'early church worship',
      '"early" names the Early Church tradition; "church" is a stopword'),
  const _Query('ent-ecumenical-councils', 'the ecumenical councils on the Holy Spirit',
      'a council by tradition name, plus the holy-spirit tag'),
  const _Query('ent-council-nicaea', 'Council of Nicaea on the Trinity',
      'a named council the core cannot recognise'),
  const _Query('ent-augustine', 'What did Augustine say about grace?',
      'a church father; no authors in the core, so nothing is recognised'),
  const _Query('ent-orthodox', 'Eastern Orthodox icons',
      'a two-word tradition name matched whole, not word by word'),

  // Mixed.
  const _Query('mix-romans-holy-spirit', 'Romans 8 and the Holy Spirit',
      'reference plus a two-word tag'),
  const _Query('mix-free-will', 'free will and predestination',
      'two multi-word tag synonyms mapping to overlapping slugs'),
  const _Query('mix-lords-supper', "the Lord's Supper",
      'apostrophe inside a tag phrase'),

  // Punctuation, case, whitespace and Unicode.
  const _Query('edge-shouting', '  BAPTISM!!!  ', 'case, punctuation, padding'),
  const _Query('edge-why-not', 'WHY NOT',
      'only stopwords, which also spell FTS5 operators'),
  const _Query('edge-nfd-nicee', 'Nicée',
      'decomposed accent (macOS paste); FTS splits at the combining mark'),
  const _Query('edge-greek', 'ὁμοούσιος', 'polytonic Greek, folded by the tokenizer'),
  const _Query('edge-accented-latin', 'Grégoire', 'precomposed Latin accent'),
  const _Query('edge-punctuation-only', '?',
      'no FTS terms at all, so the LIKE fallback runs and finds rows'),
  const _Query('edge-empty', '', 'empty input'),
  _Query('edge-long', _longQuery,
      'longer than the encoder window; exercises the 256-token truncation'),

  // Nothing lexical, and a scope that admits nothing: every stage is empty.
  const _Query('empty-result', 'Lutheran xyzzyplugh',
      'empty final result: scoped away from semantic, nothing for FTS or LIKE'),
];

final String _longQuery = List.filled(300, 'grace').join(' ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('search goldens', () async {
    // The same SQLite the app opens: main.dart routes every database through
    // the FFI factory and its bundled, FTS5-enabled library.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final raw = await _openCoreCorpus();
    final calls = <_Call>[];
    final recorded = _RecordingDatabase(raw, calls);

    final service = DatabaseService()..useForTesting(recorded);
    final realSemantic = await SemanticSearch.tryLoad(raw);
    expect(realSemantic, isNotNull, reason: 'the model must load on macOS');
    service.semantic = _RecordingSemantic(realSemantic!, calls);

    final tokenizer = await WordPieceTokenizer.load();
    final encoder = await QueryEncoder.load();
    final index = await VectorIndex.load(raw);
    final recogniser = await service.recogniser;

    Future<int> count(String table) async =>
        (await raw.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n']
            as int;

    final records = <Map<String, Object?>>[];
    for (final q in _queries) {
      final record = <String, Object?>{
        'id': q.id,
        'query': q.text,
        'why': q.why,
      };

      record['tokenIds'] = tokenizer.encode(q.text);

      final vector = await encoder.encode(q.text);
      record['vector'] = [for (final v in vector) v];
      record['vectorTop'] = [
        for (final m in index.search(vector, limit: _vectorTopLimit))
          [m.chunkId, m.contentUnitId, m.score],
      ];

      final entities = recogniser.recognise(q.text);
      record['entities'] = {
        'sourceIds': entities.sourceIds.toList()..sort(),
        'traditionIds': entities.traditionIds.toList()..sort(),
        'labels': entities.labels,
      };

      record['ftsMatch'] = DatabaseService.ftsMatchQuery(q.text);
      record['tags'] = service.extractTags(q.text);

      // The Read tab: lexical only.
      calls.clear();
      final readRows = await service.search(q.text, limit: _readLimit);
      record['read'] = {
        'path': [for (final c in calls) c.kind],
        'ids': _ids(readRows),
        'ranks': _ranks(readRows),
      };

      // The chat screen: hybrid.
      calls.clear();
      final ragRows = await service.searchForRAG(q.text, limit: _ragLimit);
      record['rag'] = _ragStages(calls, ragRows);

      records.add(record);
    }

    final golden = <String, Object?>{
      'corpusVersion': DatabaseService.corpusVersion,
      'idSpace': DatabaseService.idSpace,
      'embeddingModel': DatabaseService.embeddingModel,
      'generator':
          'integration_test/search_golden_test.dart against assets/theology.db.gz '
              '(core only, no packs). Regenerate with tools/search_goldens.sh '
              '--update; never edit by hand.',
      'corpus': {
        'sources': await count('sources'),
        'contentUnits': await count('content_units'),
        'chunks': await count('content_chunks'),
        'embeddings': await count('chunk_embeddings'),
        'vectorIndexLength': index.length,
      },
      'parameters': {
        'ragLimit': _ragLimit,
        'readLimit': _readLimit,
        'fusionLimit': _fusionLimit,
        'semanticLimit': _fusionLimit,
        'vectorTopLimit': _vectorTopLimit,
        'rrfK': HybridRanker.k,
        'maxTokens': WordPieceTokenizer.maxTokens,
        'dims': QueryEncoder.dims,
      },
      'queries': records,
    };

    final text = '${_pretty(golden)}\n';

    if (_update) {
      _emit(text);
      return;
    }

    final expected = jsonDecode(await _loadExpected());
    final actual = jsonDecode(text);
    final problems = <String>[];
    _compare(expected, actual, r'$', problems);
    if (problems.isNotEmpty) {
      fail('search.json does not match the current code '
          '(${problems.length} difference(s); first ${problems.take(40).length} '
          'below). If the change is intended, run '
          'tools/search_goldens.sh --update and commit the new fixture.\n'
          '${problems.take(40).join('\n')}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Unpack the bundled corpus to a fresh file and open it.
///
/// Not [DatabaseService.initialize]: that reuses whatever database the app's
/// container already holds when its version stamp matches, and on a machine
/// that has run Council that is a library with packs installed. The fixture
/// must be the core corpus alone, reproducible from the repository.
Future<Database> _openCoreCorpus() async {
  final dir = Directory('${Directory.systemTemp.path}/council_search_golden');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final path = '${dir.path}/theology.db';
  final data = await rootBundle.load('assets/theology.db.gz');
  File(path).writeAsBytesSync(gzip.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
  final db = await databaseFactory.openDatabase(path);
  addTearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return db;
}

List<int> _ids(List<Map<String, Object?>> rows) =>
    [for (final r in rows) r['id'] as int];

/// FTS5 `rank` (bm25) per row, or null for rows from the LIKE fallback.
List<double?> _ranks(List<Map<String, Object?>> rows) =>
    [for (final r in rows) (r['rank'] as num?)?.toDouble()];

/// Split what `searchForRAG` did into its stages, from the recorded calls.
Map<String, Object?> _ragStages(
  List<_Call> calls,
  List<Map<String, Object?>> rows,
) {
  final semanticAt = calls.indexWhere((c) => c.kind == 'semantic');
  if (semanticAt < 0) throw StateError('searchForRAG never ran semantic search');
  final before = calls.sublist(0, semanticAt);
  final after = calls.sublist(semanticAt + 1);

  final unclassified = calls.where((c) => c.kind == 'other');
  if (unclassified.isNotEmpty) {
    throw StateError('unrecognised query in searchForRAG — update _Call.classify:'
        '\n${unclassified.first.sql}');
  }

  const lexicalKinds = {'ftsScoped', 'fts', 'like'};
  final lexicalCalls = before.where((c) => lexicalKinds.contains(c.kind));
  final tagCalls = before.where((c) => c.kind == 'tags').toList();
  final semantic = calls[semanticAt];

  // searchForRAG assigns ftsResults from each lexical call in turn — scoped,
  // then the unscoped fallback, then its LIKE fallback — so the rows fused are
  // the last ones fetched.
  final lexical = lexicalCalls.isEmpty ? <int>[] : lexicalCalls.last.ids;
  final tags = tagCalls.isEmpty ? <int>[] : tagCalls.single.ids;

  return {
    'lexicalCalls': [
      for (final c in lexicalCalls)
        {
          'kind': c.kind,
          'limit': c.limit,
          'ids': c.ids,
          'ranks': c.ranks,
        },
    ],
    'lexical': lexical,
    'tagIds': tags,
    'semanticLimit': semantic.limit,
    'allowedUnitIds':
        semantic.allowed == null ? null : _ranges(semantic.allowed!),
    'allowedUnitCount': semantic.allowed?.length,
    'semantic': semantic.ids,
    'fused': HybridRanker.fuse(
      lexical: lexical,
      semantic: semantic.ids,
      tags: tags,
      limit: _fusionLimit,
    ),
    'namedTraditionCalls': [
      for (final c in after.where((c) => c.kind == 'ftsScoped'))
        {'limit': c.limit, 'ids': c.ids, 'ranks': c.ranks},
    ],
    'final': _ids(rows),
    'finalContent': [
      for (final r in rows)
        {
          'id': r['id'],
          'length': (r['content'] as String).length,
          'head': _head(r['content'] as String),
        },
    ],
  };
}

String _head(String s) => s.length <= 48 ? s : s.substring(0, 48);

/// A set of ids as sorted inclusive [start, end] runs.
List<List<int>> _ranges(Set<int> ids) {
  final sorted = ids.toList()..sort();
  final runs = <List<int>>[];
  for (final id in sorted) {
    if (runs.isNotEmpty && runs.last[1] == id - 1) {
      runs.last[1] = id;
    } else {
      runs.add([id, id]);
    }
  }
  return runs;
}

class _Call {
  final String kind;
  final String sql;
  final List<Object?> args;
  final List<int> ids;
  final List<double?> ranks;
  final Set<int>? allowed;

  _Call(this.kind, this.sql, this.args, this.ids, this.ranks, {this.allowed});

  /// The trailing LIMIT argument, for the queries that take one.
  int? get limit => kind == 'semantic'
      ? args.single as int
      : (args.isNotEmpty && args.last is int ? args.last as int : null);

  static String classify(String sql) {
    if (sql.contains('content_fts MATCH ?')) {
      return sql.contains('AND (') ? 'ftsScoped' : 'fts';
    }
    if (sql.contains('LIKE ?')) return 'like';
    if (sql.contains('tg.slug IN')) return 'tags';
    if (sql.contains('SELECT cu.id FROM content_units cu')) return 'scopeUnits';
    if (sql.contains('WHERE cu.id IN')) return 'unitsByIds';
    if (sql.contains('FROM traditions WHERE id IN')) return 'traditionNames';
    return 'other';
  }
}

/// Delegates to the real database and records every raw query with its rows.
class _RecordingDatabase implements Database {
  final Database _inner;
  final List<_Call> _calls;

  _RecordingDatabase(this._inner, this._calls);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await _inner.rawQuery(sql, arguments);
    final kind = _Call.classify(sql);
    final hasIds = rows.isNotEmpty && rows.first.containsKey('id');
    _calls.add(_Call(
      kind,
      sql,
      arguments ?? const [],
      hasIds ? _ids(rows) : const [],
      kind == 'fts' || kind == 'ftsScoped' ? _ranks(rows) : const [],
    ));
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used by search');
}

/// Delegates to the real semantic search and records each ranking it returns.
class _RecordingSemantic implements SemanticSearch {
  final SemanticSearch _inner;
  final List<_Call> _calls;

  _RecordingSemantic(this._inner, this._calls);

  @override
  int get vectorCount => _inner.vectorCount;

  @override
  Future<void> reload() => _inner.reload();

  @override
  void dispose() => _inner.dispose();

  @override
  Future<List<int>> rankedUnits(
    String query, {
    int limit = 30,
    Set<int>? allowedUnitIds,
  }) async {
    final ids = await _inner.rankedUnits(
      query,
      limit: limit,
      allowedUnitIds: allowedUnitIds,
    );
    _calls.add(_Call('semantic', '', [limit], ids, const [],
        allowed: allowedUnitIds));
    return ids;
  }
}

/// The checked-in fixture, served to the sandboxed test by the helper script.
Future<String> _loadExpected() async {
  if (_goldenUrl.isEmpty) {
    fail('No SEARCH_GOLDEN_URL. The macOS debug build is sandboxed and cannot '
        'read the repository, so run this test through '
        'tools/search_goldens.sh, which serves the fixture to it.');
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(_goldenUrl));
    final response = await request.close();
    if (response.statusCode != 200) {
      fail('GET $_goldenUrl returned ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Print the fixture for the helper script to reassemble: gzip, base64, then
/// fixed-width lines between markers, so nothing in the log path can reflow,
/// trim or truncate it.
void _emit(String text) {
  final encoded = base64.encode(gzip.encode(utf8.encode(text)));
  // ignore: avoid_print
  print('SEARCH_GOLDEN_BEGIN');
  for (var i = 0; i < encoded.length; i += 4000) {
    final end = i + 4000 < encoded.length ? i + 4000 : encoded.length;
    // ignore: avoid_print
    print('SEARCH_GOLDEN:${encoded.substring(i, end)}');
  }
  // ignore: avoid_print
  print('SEARCH_GOLDEN_END');
}

void _compare(Object? want, Object? got, String path, List<String> out) {
  if (want is Map && got is Map) {
    for (final key in {...want.keys, ...got.keys}) {
      if (!want.containsKey(key)) {
        out.add('$path.$key: unexpected (not in fixture)');
      } else if (!got.containsKey(key)) {
        out.add('$path.$key: missing (in fixture, not produced)');
      } else {
        _compare(want[key], got[key], '$path.$key', out);
      }
    }
  } else if (want is List && got is List) {
    if (want.length != got.length) {
      out.add('$path: length ${got.length}, fixture has ${want.length}');
    }
    final n = want.length < got.length ? want.length : got.length;
    for (var i = 0; i < n; i++) {
      _compare(want[i], got[i], '$path[$i]', out);
    }
  } else if (want is num && got is num && (want is double || got is double)) {
    if ((want - got).abs() > _tolerance) {
      out.add('$path: $got, fixture has $want');
    }
  } else if (want != got) {
    out.add('$path: ${jsonEncode(got)}, fixture has ${jsonEncode(want)}');
  }
}

/// JSON with one value per line, except that a list or object holding only
/// scalars stays on one line — so a vector is one line and a ranking is one
/// line, and a diff of the fixture shows which stage moved.
String _pretty(Object? value, [String indent = '']) {
  bool scalar(Object? v) => v is! Map && v is! List;
  final inner = '$indent  ';

  if (value is Map) {
    if (value.isEmpty || value.values.every(scalar)) return jsonEncode(value);
    final entries = [
      for (final e in value.entries)
        '$inner${jsonEncode(e.key)}: ${_pretty(e.value, inner)}',
    ];
    return '{\n${entries.join(',\n')}\n$indent}';
  }
  if (value is List) {
    if (value.isEmpty || value.every(scalar)) return jsonEncode(value);
    final items = [for (final v in value) '$inner${_pretty(v, inner)}'];
    return '[\n${items.join(',\n')}\n$indent]';
  }
  return jsonEncode(value);
}

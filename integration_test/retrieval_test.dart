import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/search/entity_recogniser.dart';
import 'package:council/src/services/search/semantic_search.dart';
import 'package:council/src/services/packs/pack_service.dart';

/// Retrieval, exercised against the real bundled corpus on a real device.
///
/// Every other test in this project runs against fixtures, and the retrieval
/// work has been verified through a Python mirror in `tools/query_probe.py`.
/// That mirror is written to match the Dart, but nothing enforced the match —
/// so a Dart-side regression could pass every test and every probe while the
/// shipped app returned the wrong passages.
///
/// These tests close that gap. They are slow and need a device, so they live
/// outside the unit suite.
///
/// Since the corpus was split into a bundled core and downloadable packs, most
/// of the patristic material is no longer present by default — so this suite
/// installs the packs first when told where to find them. Without them it
/// still runs, over the core corpus, and the tests that need the fathers say
/// plainly that they were skipped rather than quietly passing:
///
///     python3 tools/build_packs.py --write
///     (cd dist/packs && python3 -m http.server 8765 &)
///     flutter test integration_test/retrieval_test.dart -d macos \
///       --dart-define=PACKS_URL=http://127.0.0.1:8765/manifest.json
/// Where to fetch content packs from, if this run should exercise the full
/// library rather than the bundled core. Empty means core only.
const _packsUrl = String.fromEnvironment('PACKS_URL', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;

  final fullCorpus = _packsUrl.isNotEmpty;
  final needsPacks = fullCorpus
      ? null
      : 'needs the content packs — see the note at the top of this file';

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
    if (!fullCorpus) return;

    final packs = PackService(db.database, manifestUrl: _packsUrl);
    final manifest = await packs.fetchManifest();
    // Every collection, so the suite runs against the whole library. They
    // overlap heavily; installing them all still fetches each fragment once.
    for (final collection in manifest.collections) {
      await packs.install(
        collection,
        manifest,
        idSpace: DatabaseService.idSpace,
      );
    }
    await db.semantic?.reload();
    packs.dispose();

  });

  Future<List<Map<String, dynamic>>> retrieve(String question) =>
      db.searchForRAG(question, limit: 6);

  Set<String> traditionsIn(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['tradition'] as String? ?? '?').toSet();

  Set<String> sourcesIn(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['source_title'] as String? ?? '?').toSet();

  group('the corpus is what we think it is', () {
    test('opens and holds the expected shape', () async {
      final stats = await db.getStats();
      // The app now bundles Scripture and nothing else; every other tradition
      // arrives as a collection. So "the expected shape" depends entirely on
      // whether they were installed.
      expect(stats['sources'], greaterThan(fullCorpus ? 400 : 0));
      expect(stats['content_units'], greaterThan(fullCorpus ? 18000 : 1000));
      expect(stats['traditions'], greaterThan(6));
    });

    test('every unit carries provenance classification', () async {
      final rows = await db.database.rawQuery(
        "SELECT count(*) AS n FROM content_units WHERE provenance IS NULL",
      );
      expect(rows.first['n'], 0);
    });
  });

  group('comparative questions', () {
    test('returns more than one tradition', () async {
      // The failure this whole line of work started from: every slot filled
      // with whichever tradition the corpus holds most of.
      final rows = await retrieve(
        'What are the differences between Catholic and Lutheran '
        'beliefs about baptism?',
      );

      expect(rows, isNotEmpty);
      expect(traditionsIn(rows).length, greaterThan(1),
          reason: 'a comparison needs more than one tradition');

      // Named specifically, not merely "more than one". Adding Aquinas put
      // 14 M characters of Catholic material against 0.79 M Lutheran, and the
      // question started returning six Catholic passages and no Lutheran ones
      // — technically several traditions once the fathers were counted, and
      // still not an answer to what was asked.
      expect(traditionsIn(rows), containsAll(['Catholic', 'Lutheran']),
          reason: 'both traditions the question named must be represented');
    }, skip: needsPacks);

    test('draws on genuine Lutheran sources, not mislabelled ones', () async {
      // Every source previously labelled Lutheran was Eastern Orthodox or
      // patristic. These are the real confessions.
      final rows = await db.database.rawQuery('''
        SELECT s.title FROM sources s
        JOIN traditions t ON s.tradition_id = t.id
        WHERE t.name = 'Lutheran'
      ''');
      final titles = rows.map((r) => r['title'] as String).toList();

      expect(titles, contains('The Augsburg Confession'));
      expect(titles, isNot(contains('The Didache')));
      expect(titles, isNot(contains('The Philokalia Selections')));
    }, skip: needsPacks);
  });

  group('citations can be checked', () {
    test('every result carries what a citation needs to show', () async {
      final rows = await retrieve('What is baptism for?');
      expect(rows, isNotEmpty);

      for (final row in rows) {
        expect(row['source_title'], isNotNull);
        expect(row.containsKey('tradition'), isTrue);
        // Present as a key even when null: the UI distinguishes "traced to a
        // published edition" from "origin never recorded", and it can only do
        // that if the column is selected at all. Dropping it from the query
        // would silently turn every citation into an unverifiable one.
        expect(row.containsKey('source_url'), isTrue);
        expect(row.containsKey('license'), isTrue);
      }
    });

    test('traceable and untraceable sources are distinguishable', () async {
      final counts = await db.database.rawQuery('''
        SELECT
          SUM(CASE WHEN source_url IS NULL OR source_url = '' THEN 1 ELSE 0 END)
            AS untraceable,
          COUNT(*) AS total
        FROM sources
      ''');
      final untraceable = counts.first['untraceable'] as int;
      final total = counts.first['total'] as int;

      expect(total, greaterThan(0));
      // Not asserted to be zero: some legacy sources genuinely have no
      // recorded origin, and the point of this work is that the app says so
      // rather than hiding it. This guards the *ability to tell*.
      expect(untraceable, lessThan(total));
    });
  });

  group('entity scoping', () {
    late EntityRecogniser recogniser;

    setUpAll(() async => recogniser = await db.recogniser);

    test('scopes a question naming a work to that work', () async {
      final scope = recogniser.recognise(
        'What did the Council of Trent decree about justification?',
      );
      expect(scope.isNotEmpty, isTrue);

      final rows = await retrieve(
        'What did the Council of Trent decree about justification?',
      );
      expect(
        sourcesIn(rows).any((s) => s.contains('Trent')),
        isTrue,
        reason: 'a question naming Trent must return Trent',
      );
    }, skip: needsPacks);

    test('scopes a question naming an author to their works', () async {
      final scope =
          recogniser.recognise('What did Augustine say about grace?');
      expect(scope.sourceIds.length, greaterThan(20),
          reason: 'Augustine has many works in the corpus');

      final rows = await retrieve('What did Augustine say about grace?');
      expect(rows, isNotEmpty);
    }, skip: needsPacks);

    test('leaves an ordinary question unscoped', () {
      // The false positives that made a rare-token rule untenable.
      expect(recogniser.recognise('How is a person saved?').isEmpty, isTrue);
      expect(recogniser.recognise('Is the Son equal to the Father?').isEmpty,
          isTrue);
    });
  });

  group('the corpus holds works, not their contents pages', () {
    /// The characters stored for a work, by title.
    Future<int> lengthOf(String title) async {
      final rows = await db.database.rawQuery('''
        SELECT COALESCE(SUM(LENGTH(u.content)), 0) AS chars
        FROM sources s JOIN content_units u ON u.source_id = s.id
        WHERE s.title = ?
      ''', [title]);
      return rows.first['chars'] as int;
    }

    // New Advent gives a long work a contents page — for the City of God,
    // Augustine's argument for each of the 22 books — and the ingester read
    // those as the work itself. It looks entirely correct from the outside:
    // right title, right author, right URL, and the words really are
    // Augustine's. It is only wrong by *length*, so length is what this pins.
    //
    // The floors are an order of magnitude under the real figures rather than
    // just over the old ones. A test that asserts 1.2 M for the City of God
    // has to be edited whenever a part is re-fetched; one that asserts 200 K
    // never fires except on the regression it exists for.
    const minimums = {
      'City of God': 200000,
      'Confessions': 100000,
      'Christian Doctrine': 100000,
      'Adversus haereses': 200000,
      'The Harmony of the Gospels': 200000,
      'Tractates on the Gospel of John': 200000,
      'Homilies on the Gospel of John': 200000,
    };

    for (final entry in minimums.entries) {
      test('${entry.key} holds its text', () async {
        expect(await lengthOf(entry.key), greaterThan(entry.value),
            reason: '${entry.key} is stored as its contents page again');
      }, skip: needsPacks);
    }

    test("the letter collections are letters, not a list of them", () async {
      // Basil's 325 letters were one 3,489-character index page. Queried by
      // author, because four fathers have a work titled simply "Letters".
      final rows = await db.database.rawQuery('''
        SELECT s.author, COUNT(u.id) AS units
        FROM sources s JOIN content_units u ON u.source_id = s.id
        WHERE s.title IN ('Letters', 'Register of Letters')
        GROUP BY s.id
      ''');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['units'] as int, greaterThan(20),
            reason: '${row['author']}\'s letters are back to an index page');
      }
    }, skip: needsPacks);

    test('both London Baptist confessions are present', () async {
      final rows = await db.database.rawQuery('''
        SELECT s.title, COUNT(u.id) AS units
        FROM sources s JOIN content_units u ON u.source_id = s.id
        JOIN traditions t ON s.tradition_id = t.id
        WHERE t.name = 'Baptist'
        GROUP BY s.id
      ''');
      final byTitle = {
        for (final row in rows) row['title'] as String: row['units'] as int,
      };

      // 1689 without 1644 reads as though Baptists began in 1689.
      expect(byTitle['The First London Baptist Confession of Faith'], 53);
      expect(byTitle['The Second London Baptist Confession of Faith'], 160);
    });

    test('the Reformation-era works hold their text', () async {
      // Same reasoning as the minimums above: floors an order of magnitude
      // under the real figures, so this only ever fires on the regression it
      // exists for. The specific regression is a CCEL export that is not a
      // transcription at all — six volumes of Spurgeon's Treasury of David
      // turned out to be "Image of page 73" placeholders, which clear a naive
      // length check because there are thousands of them.
      const minimums = {
        'The Institutes of the Christian Religion': 1000000,
        'Commentary on the Whole Bible Volume I (Genesis to Deuteronomy)': 1000000,
        "Spurgeon's Sermons Volume 01: 1855": 500000,
      };

      for (final entry in minimums.entries) {
        final rows = await db.database.rawQuery('''
          SELECT COALESCE(SUM(LENGTH(u.content)), 0) AS chars
          FROM sources s JOIN content_units u ON u.source_id = s.id
          WHERE s.title = ?
        ''', [entry.key]);
        expect(rows.first['chars'] as int, greaterThan(entry.value),
            reason: '${entry.key} is not holding its text');
      }
    }, skip: needsPacks);

    test('no unit is too large to chunk', () async {
      // Not a readability nicety. Chunk ids are derived as
      // `unit_id * 1000 + sequence`, so a unit yielding more than a thousand
      // chunks runs into the next unit's id range — and because embeddings are
      // keyed on chunk id, retrieval then returns vectors belonging to
      // unrelated text without anything erroring. One unit reached 5.4 M
      // characters before this was caught.
      final rows = await db.database.rawQuery('''
        SELECT id, title, LENGTH(content) AS chars
        FROM content_units
        ORDER BY LENGTH(content) DESC
        LIMIT 1
      ''');
      expect(rows.first['chars'] as int, lessThan(1000 * 1200),
          reason: 'unit ${rows.first['id']} (${rows.first['title']}) '
              'would collide with the next unit\'s chunk ids');
    });

    test('the corpus holds no scripture indexes', () async {
      // Matthew Henry's volumes each close with one. 6.5 M characters of
      // "Isaiah 1:1 ... 1:2 ..." reads as prose to every check that looks at
      // length, and answers nothing.
      final rows = await db.database.rawQuery('''
        SELECT title FROM content_units
        WHERE title LIKE 'Index of %' OR title LIKE 'Scripture Index%'
      ''');
      expect(rows, isEmpty,
          reason: 'indexes ingested as text: '
              '${rows.take(3).map((r) => r['title']).join(', ')}');
    }, skip: needsPacks);

    test('the Eastern Orthodox tradition is not empty', () async {
      // It was, for one build: both entries were removed as misattributed —
      // one of them filed Pilgrim's Progress as the Philokalia — and the
      // tradition was left as a row in the database with nothing in it. A
      // count is the cheapest guard against a removal that is never replaced.
      final rows = await db.database.rawQuery('''
        SELECT s.title, COUNT(u.id) AS units
        FROM sources s
        JOIN content_units u ON u.source_id = s.id
        JOIN traditions t ON s.tradition_id = t.id
        WHERE t.name = 'Eastern Orthodox'
        GROUP BY s.id
      ''');
      final byTitle = {
        for (final row in rows) row['title'] as String: row['units'] as int,
      };

      // Philaret's catechism runs to 611 numbered questions; the transcription
      // drops one outright and prints two without answers, so 608 is the whole
      // of what it holds. Pinned exactly, because the number moving means the
      // page moved.
      expect(
        byTitle['The Longer Catechism of the Orthodox, Catholic, Eastern Church'],
        608,
      );
      expect(byTitle['The Confession of Dositheus'], 22);
      expect(byTitle['The Book of Needs of the Holy Orthodox Church'],
          greaterThan(50));
    });

    test('the corpus holds no reference apparatus', () async {
      // Every CCEL export ends with a colophon and a numbered list resolving
      // each hyperlink to a `file:///ccel/...` path. 3,438 units of it shipped
      // — about 30 M characters — because a page of link targets is long
      // enough to clear any floor expressed in characters. It reads as text,
      // retrieves as text and says nothing, which is the scripture-index
      // defect arriving through a different door.
      final rows = await db.database.rawQuery('''
        SELECT id, title FROM content_units
        WHERE content LIKE '%file:///ccel/%'
           OR content LIKE 'This document is from the Christian Classics%'
        LIMIT 5
      ''');
      expect(rows, isEmpty,
          reason: 'link tables ingested as text: '
              '${rows.map((r) => '${r['id']} ${r['title']}').join(', ')}');
    }, skip: needsPacks);

    test('Owen and the Treasury of David hold their text', () async {
      // Both were refused by the previous build and recovered by corroborating
      // the transcription against a scan of the printing it descends from. The
      // floors are well under the real figures, so this fires on a work going
      // missing rather than on a re-fetch.
      final rows = await db.database.rawQuery('''
        SELECT s.author, COUNT(DISTINCT s.id) AS works,
               SUM(LENGTH(u.content)) AS chars
        FROM sources s JOIN content_units u ON u.source_id = s.id
        WHERE s.author = 'John Owen' OR s.title LIKE 'The Treasury of David%'
        GROUP BY s.author = 'John Owen'
      ''');
      final byAuthor = {
        for (final row in rows)
          row['author'] as String: (
            works: row['works'] as int,
            chars: row['chars'] as int,
          ),
      };

      expect(byAuthor['John Owen']?.works, 31);
      expect(byAuthor['John Owen']?.chars, greaterThan(15000000));

      // The Treasury is filed under Spurgeon's name, so it is found by title.
      // Six records, one per psalm range, covering all 150.
      expect(byAuthor['Charles Haddon Spurgeon']?.works, 6);
      expect(byAuthor['Charles Haddon Spurgeon']?.chars, greaterThan(8000000));
    }, skip: needsPacks);

    test('the Treasury covers every psalm', () async {
      // Psalm 119 is a volume of the original in its own right and is the one
      // most easily lost: it opens with a preface rather than the navigation
      // block every other psalm carries, so a parser keyed on headings drops
      // it. The transcription that was rejected in favour of this one was
      // missing 119 and ten others.
      final rows = await db.database.rawQuery('''
        SELECT u.title AS title FROM content_units u
        JOIN sources s ON s.id = u.source_id
        WHERE s.title LIKE 'The Treasury of David%'
      ''');
      final covered = <int>{};
      for (final row in rows) {
        final match =
            RegExp(r'^Psalm (\d+)').firstMatch(row['title'] as String);
        if (match != null) covered.add(int.parse(match.group(1)!));
      }
      final missing = [
        for (var psalm = 1; psalm <= 150; psalm++)
          if (!covered.contains(psalm)) psalm,
      ];
      expect(missing, isEmpty, reason: 'psalms with no commentary: $missing');
    }, skip: needsPacks);

    test('no tradition claims coverage it does not have', () async {
      // The inverse of the test above, and the more important one. Three
      // traditions are honestly uncovered — their defining documents are
      // 20th-century and in copyright — and that is recorded in SOURCES.md
      // rather than papered over with summaries. Every *other* tradition
      // having a row must have text behind it.
      const knownEmpty = {'Universal', 'Oriental Orthodox', 'Pentecostal'};

      final rows = await db.database.rawQuery('''
        SELECT t.name, COUNT(s.id) AS sources
        FROM traditions t
        LEFT JOIN sources s ON s.tradition_id = t.id
        GROUP BY t.id
      ''');

      for (final row in rows) {
        final name = row['name'] as String;
        if (knownEmpty.contains(name)) continue;
        expect(row['sources'] as int, greaterThan(0),
            reason: '$name has a row in the table and nothing in it');
      }
    });

    test('nothing in the corpus lacks a recorded origin', () async {
      // Eight sources had no source_url, and reading their unit titles in
      // order showed why that mattered: each was two unrelated works
      // interleaved — Pilgrim's Progress filed as the Philokalia, Nostra
      // Aetate under Gregory of Nyssa. A missing origin is the symptom.
      final rows = await db.database.rawQuery('''
        SELECT title FROM sources
        WHERE source_url IS NULL OR source_url = ''
      ''');
      expect(rows, isEmpty,
          reason: 'unsourced: ${rows.map((r) => r['title']).join(', ')}');
    });
  });

  group('hybrid retrieval', hybridTests);

  group('passage selection', () {
    test('returns a readable slice of an enormous unit', () async {
      // Augustine's Enchiridion runs to 162,014 characters. Before chunking,
      // retrieval handed the model its first 1,500 and everything else was
      // invisible.
      final rows = await retrieve('What is the resurrection of the body?');
      expect(rows, isNotEmpty);

      for (final row in rows) {
        final content = row['content'] as String? ?? '';
        expect(content.length, lessThan(20000),
            reason: 'a retrieved passage must be readable, not a whole book');
        expect(content.trim(), isNotEmpty);
      }
    });

    test('every result carries a source and a tradition', () async {
      // A citation the reader cannot attribute is not a citation.
      final rows = await retrieve('How is a person saved?');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['source_title'], isNotNull);
        expect(row['id'], isNotNull);
      }
    });
  });
}

/// Hybrid retrieval — lexical and semantic together, as the app runs it.
///
/// Kept in this file rather than the encoder's so it exercises the real
/// `searchForRAG` path, including scope, fusion and diversification.
void hybridTests() {
  late DatabaseService db;

  setUpAll(() async {
    db = DatabaseService();
    await db.initialize();
    db.semantic = await SemanticSearch.tryLoad(db.database);
  });

  test('semantic search is actually available', () {
    expect(db.semantic, isNotNull,
        reason: 'the model should load on a supported platform');
    // The core corpus carries 2,683 vectors; the full library carries 54,854.
    expect(db.semantic!.vectorCount,
        greaterThan(_packsUrl.isEmpty ? 2000 : 50000));
  });

  test('answers a question whose words are not in the answer', () async {
    // The whole point of the semantic half: this shares almost no vocabulary
    // with confessional language about justification.
    final rows = await db.searchForRAG('How is a person saved?', limit: 6);
    expect(rows, isNotEmpty);
    for (final row in rows) {
      expect((row['content'] as String).trim(), isNotEmpty);
    }
  });

  test('degrades to lexical when the model is absent', () async {
    final lexicalOnly = DatabaseService();
    await lexicalOnly.initialize();
    lexicalOnly.semantic = null;

    final rows = await lexicalOnly.searchForRAG('baptism', limit: 5);
    expect(rows, isNotEmpty,
        reason: 'no model must mean worse search, not broken search');
  });
}

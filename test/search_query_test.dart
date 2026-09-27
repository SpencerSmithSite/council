import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/services/database_service.dart';

/// What a query has to survive on its way to FTS5.
///
/// The corpus is patristic and Reformation theology, so the words it is most
/// particular about are exactly the ones that were being destroyed: Küng,
/// Grégoire, Νίκαια, ὁμοούσιος. `RegExp(r'[^\w\s]')` looks like it strips
/// punctuation, and in Dart it strips every letter outside ASCII too — `\w` is
/// not Unicode-aware. FTS5 was never the obstacle; its unicode61 tokenizer
/// indexes Greek and folds diacritics, so the letters only had to reach it.
///
/// The other half is FTS5's own grammar. A bareword that spells an operator is
/// one, and the all-stopwords fallback hands the reader's words back as typed.
void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute('CREATE VIRTUAL TABLE content_fts USING fts5(content)');
    for (final line in const [
      'Hans Küng wrote against infallibility',
      'Grégoire de Nazianze on the Trinity',
      'ὁμοούσιος means of one substance',
      'The council at Νίκαια settled the question',
      'why not consider the case for baptism',
      'Growth of one hundred percent, or 100% of the whole',
      'The __init__ of a thing is its beginning',
    ]) {
      await db.insert('content_fts', {'content': line});
    }
  });

  tearDown(() async => db.close());

  /// Run a built match expression the way `search` does.
  Future<List<String>> matching(String query) async {
    final expression = DatabaseService.ftsMatchQuery(query);
    if (expression.isEmpty) return const [];
    final rows = await db.rawQuery(
      'SELECT content FROM content_fts WHERE content_fts MATCH ? '
      'ORDER BY rank',
      [expression],
    );
    return rows.map((r) => r['content'] as String).toList();
  }

  group('a query keeps its letters, whatever script they are in', () {
    test('an umlaut is not deleted from the middle of a name', () {
      // "Küng" became "K ng", both pieces too short to survive, so the whole
      // query came out empty and fell through to an unindexed corpus scan.
      expect(DatabaseService.ftsMatchQuery('Küng'), isNotEmpty);
      expect(DatabaseService.ftsMatchQuery('Küng'), contains('Küng'));
    });

    test('an accent does not truncate a name to its tail', () {
      // The old output for this was `goire* OR Nazianze*`: the accented word
      // lost its first three letters, the unaccented one came through intact.
      final built = DatabaseService.ftsMatchQuery('Grégoire de Nazianze');
      expect(built, contains('Grégoire'));
      expect(built, contains('Nazianze'));
    });

    test('a wholly Greek query survives', () {
      expect(DatabaseService.ftsMatchQuery('ὁμοούσιος'), contains('ὁμοούσιος'));
      expect(DatabaseService.ftsMatchQuery('Νίκαια'), contains('Νίκαια'));
    });

    test('punctuation is still separated out', () {
      final built = DatabaseService.ftsMatchQuery('baptism, and regeneration!');
      expect(built, isNot(contains(',')));
      expect(built, isNot(contains('!')));
    });
  });

  group('the built expression finds what it should', () {
    test('an accented name is found', () async {
      expect(await matching('Küng'), contains('Hans Küng wrote against infallibility'));
    });

    test('an unaccented spelling still finds the accented text', () async {
      // FTS5 folds diacritics, which is why preserving them costs nothing.
      expect(await matching('gregoire'),
          contains('Grégoire de Nazianze on the Trinity'));
    });

    test('a Greek term is found', () async {
      expect(await matching('ὁμοούσιος'), contains('ὁμοούσιος means of one substance'));
    });

    test('a Greek place name is found', () async {
      expect(await matching('Νίκαια'),
          contains('The council at Νίκαια settled the question'));
    });
  });

  group('FTS5 operators cannot be spelled by accident', () {
    test('an all-stopword question in capitals does not throw', () async {
      // "WHY NOT": both stopwords, so the fallback re-admits them as typed, and
      // `WHY* OR NOT*` is a syntax error. Read's search has no catch, so the
      // spinner turned for good.
      expect(DatabaseService.ftsMatchQuery('WHY NOT'), isNotEmpty);
      expect(await matching('WHY NOT'),
          contains('why not consider the case for baptism'));
    });

    test('AND, OR and NEAR as the whole query are terms, not operators',
        () async {
      for (final query in const ['AND', 'OR NOT', 'NEAR AND', 'and not']) {
        await expectLater(matching(query), completes,
            reason: '"$query" must be searched for, not parsed');
      }
    });

    test('a quote in the query does not break out of the term', () async {
      await expectLater(matching('say "this" and that'), completes);
    });
  });

  group('LIKE wildcards in a query are literal', () {
    test('a percent sign is escaped', () {
      expect(DatabaseService.escapeLike('100%'), r'100\%');
    });

    test('an underscore is escaped', () {
      expect(DatabaseService.escapeLike('__init__'), r'\_\_init\_\_');
    });

    test('a backslash is escaped first, so escapes are not doubled wrongly', () {
      expect(DatabaseService.escapeLike(r'a\b'), r'a\\b');
    });

    test('a query that is itself a wildcard no longer matches the corpus',
        () async {
      // The sharp case. A reader searching for an underscore — or for "_test",
      // or a bare "%" — sent LIKE a pattern made of nothing but wildcards, and
      // every unit in the corpus came back as a match. That is the most
      // expensive query in the app returning forty arbitrary passages.
      await db.execute('CREATE TABLE units (content TEXT)');
      await db.insert('units', {'content': 'The __init__ of a thing'});
      await db.insert('units', {'content': 'Baptism and regeneration'});
      await db.insert('units', {'content': 'The Nicene Creed'});

      final escaped = await db.rawQuery(
        "SELECT content FROM units WHERE content LIKE ? ESCAPE '\\'",
        ['%${DatabaseService.escapeLike('_')}%'],
      );
      expect(escaped.map((r) => r['content']), ['The __init__ of a thing'],
          reason: 'only the row with a literal underscore in it');

      final unescaped = await db.rawQuery(
        'SELECT content FROM units WHERE content LIKE ?',
        ['%_%'],
      );
      expect(unescaped, hasLength(3),
          reason: 'which is the bug: the whole table, presented as results');
    });
  });
}

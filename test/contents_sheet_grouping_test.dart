import 'package:council/src/screens/source_reader_screen.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// How the jump-to sheet presents a long work, and that the presentation holds
/// still while the reader types.
///
/// The bug this pins: the grouped-or-flat choice was made from whatever the
/// filter currently matched, so it flipped with the query. "prove" matched
/// Proverbs' 31 chapters and grouped them into chips; "Corinth" matched 29 and
/// fell back to a flat list of rows — the same Bible in two different shapes
/// depending on which book you went looking for, with the seam falling at an
/// arbitrary count rather than anywhere the reader could see.
void main() {
  late Database corpus;
  late Database userDb;
  late DatabaseService db;

  // Enough of the canon to straddle the old threshold: Proverbs is over it at
  // 31 chapters, Corinthians under it at 29 across its two letters, and Malachi
  // far under at 4.
  const books = [
    ('Genesis', 50),
    ('Psalms', 150),
    ('Proverbs', 31),
    ('1 Corinthians', 16),
    ('2 Corinthians', 13),
    ('Malachi', 4),
  ];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    corpus = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await corpus.execute('CREATE TABLE traditions (id INTEGER PRIMARY KEY, '
        'name TEXT)');
    await corpus.execute('CREATE TABLE source_types (id INTEGER PRIMARY KEY, '
        'name TEXT)');
    await corpus.execute('CREATE TABLE sources (id INTEGER PRIMARY KEY, '
        'title TEXT, author TEXT, date_composed TEXT, source_url TEXT, '
        'license TEXT, tradition_id INTEGER, source_type_id INTEGER)');
    await corpus.execute('CREATE TABLE content_units (id INTEGER PRIMARY KEY, '
        'source_id INTEGER, sequence INTEGER, title TEXT, unit_number INTEGER, '
        'unit_type TEXT, content TEXT)');

    await corpus.insert('traditions', {'id': 1, 'name': 'Scripture'});
    await corpus.insert('sources', {
      'id': 1,
      'title': 'The Holy Bible: King James Version',
      'date_composed': '1611',
      'tradition_id': 1,
    });

    var id = 1;
    var sequence = 0;
    for (final (book, chapters) in books) {
      for (var chapter = 1; chapter <= chapters; chapter++) {
        await corpus.insert('content_units', {
          'id': id++,
          'source_id': 1,
          'sequence': sequence++,
          'title': '$book $chapter',
          'unit_number': chapter,
          'unit_type': 'chapter',
          'content': 'The words of the Preacher, the son of David.',
        });
      }
    }

    userDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(userDb);
    db = DatabaseService()..useForTesting(corpus);
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await corpus.close();
    await userDb.close();
  });

  /// `testWidgets` drives a fake clock while sqflite completes on the real
  /// event loop, so the screen's queries need real time to land.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// Open the reader and pull up the jump-to sheet.
  Future<void> openContents(WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider()),
      ],
      child: const MaterialApp(
        home: SourceReaderScreen(
          sourceId: 1,
          title: 'The Holy Bible: King James Version',
          initialIndex: 0,
        ),
      ),
    ));
    await settle(tester);

    await tester.tap(find.byIcon(Icons.list));
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await settle(tester);
  }

  /// Text inside the list, ignoring the identical string the reader just typed
  /// into the filter field above it.
  Finder inList(String text) => find.descendant(
        of: find.byType(ExpansionTile),
        matching: find.text(text),
      );

  /// A book is grouped when its name stands alone as a header — the chapters
  /// behind it are chips numbered "1", "2", not rows reading "1 Corinthians 1".
  void expectGrouped(String book, int chapters) {
    expect(inList(book), findsOneWidget,
        reason: '$book should head a group of its own');
    expect(inList('$chapters sections'), findsOneWidget,
        reason: "$book's group should count its chapters");
    expect(find.text('$book 1'), findsNothing,
        reason: '$book is grouped, so no row should repeat the book name');
  }

  testWidgets('a book under the old count threshold still groups',
      (tester) async {
    await openContents(tester);

    // 29 chapters across the two letters — one short of the old cutoff, which
    // is what dropped it to a flat list.
    await type(tester, 'Corinth');

    expectGrouped('1 Corinthians', 16);
    expectGrouped('2 Corinthians', 13);
  });

  testWidgets('a very short book groups too', (tester) async {
    await openContents(tester);
    await type(tester, 'Malachi');

    expectGrouped('Malachi', 4);
    // The only match, so it opens without a tap: naming a book is a request to
    // see inside it.
    expect(find.widgetWithText(ActionChip, '4'), findsOneWidget);
  });

  testWidgets('a book over the old threshold groups, as it always did',
      (tester) async {
    await openContents(tester);
    await type(tester, 'prove');

    expectGrouped('Proverbs', 31);
  });

  testWidgets('the shape does not change as the reader types', (tester) async {
    await openContents(tester);

    // Every prefix of a book name keeps the same presentation, however many
    // chapters it happens to match on the way through — "C" alone catches 33
    // across three books, "Corinth" 29 across two, and the old code changed
    // shape between those two counts.
    for (final query in ['C', 'Co', 'Cor', 'Corin', 'Corinth']) {
      await type(tester, query);
      expect(find.byType(ExpansionTile), findsWidgets,
          reason: 'books should still head groups after typing "$query"');
      expect(find.text('1 Corinthians 1'), findsNothing,
          reason: 'typing "$query" should not fall back to flat rows');
    }
  });

  testWidgets('an expanded book does not leave a later one hanging open',
      (tester) async {
    await openContents(tester);

    await type(tester, 'Malachi');
    expect(find.widgetWithText(ActionChip, '4'), findsOneWidget);

    // Malachi's expansion must not carry over to whatever book now stands in
    // its place: the tile is keyed by book, not by row.
    await type(tester, 'Genesis');
    expect(inList('Genesis'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '50'), findsOneWidget);
    expect(inList('4 sections'), findsNothing);
  });
}

import 'package:council/src/screens/content_detail_screen.dart';
import 'package:council/src/screens/source_reader_screen.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Following a citation into the work it was taken from.
///
/// A cited passage is opened as a card of its own, and the objection to a
/// quotation is nearly always about what surrounds it — so that card has to
/// lead into the whole work, landing on the section quoted rather than on the
/// work's first page. The part with something to get wrong is the landing: a
/// citation knows the passage's id and not its place in the running order, so
/// the position is resolved against the same ordering the pager walks.
void main() {
  late Database corpus;
  late Database userDb;
  late DatabaseService db;

  const sections = [
    (id: 501, sequence: 1, title: '28.4. Of Baptism', body: 'Not only those'),
    (id: 502, sequence: 2, title: '28.5. Of Baptism', body: 'Although it be'),
    (id: 503, sequence: 3, title: '28.6. Of Baptism', body: 'THE efficacy of'),
    (id: 504, sequence: 4, title: '28.7. Of Baptism', body: 'The sacrament of'),
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
    // Only what the reader's two queries touch: the running order, and the
    // joins `getContentUnit` makes onto the source.
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
    await corpus.execute('CREATE TABLE tags (id INTEGER PRIMARY KEY, '
        'name TEXT, slug TEXT, category TEXT)');
    await corpus.execute('CREATE TABLE content_tags (content_unit_id INTEGER, '
        'tag_id INTEGER)');
    await corpus.insert('sources', {
      'id': 7,
      'title': 'The Westminster Confession of Faith',
    });
    for (final section in sections) {
      await corpus.insert('content_units', {
        'id': section.id,
        'source_id': 7,
        'sequence': section.sequence,
        'title': section.title,
        'unit_type': 'article',
        'content': section.body,
      });
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

  /// Let the queries a screen started actually run.
  ///
  /// `testWidgets` drives a fake clock and sqflite completes on the real event
  /// loop, so without turning the real loop here nothing the screen asked for
  /// ever arrives. Pumped a fixed number of frames rather than settled: a
  /// screen that is still loading is showing a spinner, and a spinner never
  /// settles.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> show(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
      ],
      child: MaterialApp(home: home),
    ));
    await settle(tester);
  }

  Future<void> open(WidgetTester tester, {int? unitId, int? index}) {
    return show(
      tester,
      SourceReaderScreen(
        sourceId: 7,
        title: 'The Westminster Confession of Faith',
        initialIndex: index,
        initialUnitId: unitId,
      ),
    );
  }

  testWidgets('a cited passage leads into the work at its own section',
      (tester) async {
    await show(tester, const ContentDetailScreen(contentId: 503));
    expect(find.textContaining('THE efficacy of'), findsOneWidget);

    await tester.tap(find.text('Read in context'));
    await settle(tester);

    // The reader, open at the cited section rather than at the confession's
    // first article — with the rest of the work either side of it.
    expect(find.text('3 of 4'), findsOneWidget);
    // More than one: the citation card is still on the stack underneath.
    expect(find.textContaining('THE efficacy of'), findsWidgets);
  });

  testWidgets('a passage whose source is unknown offers no way in',
      (tester) async {
    // Through `runAsync`, because the test body runs on a fake clock and
    // sqflite completes on the real one — awaiting a query directly here
    // simply never returns.
    await tester.runAsync(() => corpus.insert('content_units', {
          'id': 600,
          'sequence': 1,
          'title': 'An orphaned passage',
          'unit_type': 'article',
          'content': 'A passage belonging to no work.',
        }));

    await show(tester, const ContentDetailScreen(contentId: 600));

    expect(find.textContaining('belonging to no work'), findsOneWidget);
    expect(find.text('Read in context'), findsNothing);
  });

  testWidgets('a cited unit opens the work at that section', (tester) async {
    await open(tester, unitId: 503);

    expect(find.textContaining('THE efficacy of'), findsOneWidget);
    expect(find.textContaining('Not only those'), findsNothing);
    // The pager agrees, so paging on from a citation continues the work rather
    // than jumping back to its opening.
    expect(find.text('3 of 4'), findsOneWidget);
  });

  testWidgets('a unit no longer in the work falls back', (tester) async {
    SharedPreferences.setMockInitialValues({'reading_position_7': 1});

    await open(tester, unitId: 9999);

    expect(find.text('2 of 4'), findsOneWidget);
  });

  testWidgets('a named index still works', (tester) async {
    await open(tester, index: 3);

    expect(find.textContaining('The sacrament of'), findsOneWidget);
    expect(find.text('4 of 4'), findsOneWidget);
  });

  testWidgets('with nothing asked for, it resumes where it stopped',
      (tester) async {
    SharedPreferences.setMockInitialValues({'reading_position_7': 2});

    await open(tester);

    expect(find.textContaining('THE efficacy of'), findsOneWidget);
    expect(find.text('3 of 4'), findsOneWidget);
  });
}

import 'package:council/src/screens/read_screen.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/inference/inference_provider.dart';
import 'package:council/src/services/packs/pack_catalogue.dart';
import 'package:council/src/services/packs/pack_provider.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The shelf groups branch → tradition, and orders both by the taxonomy.
///
/// The ordering is the part worth pinning. Every obvious implementation of a
/// grouped list sorts by name, and sorting these by name is wrong in a way
/// that looks fine: it puts Adventist above Anglican, and the Reformation
/// above Chalcedon. The fixture below is built so that taxonomy order and
/// alphabetical order disagree, because a fixture where they agree cannot tell
/// the two apart.
void main() {
  late Database corpus;
  late Database userDb;
  late DatabaseService db;
  late PackProvider packs;

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
    await corpus.execute('CREATE TABLE branches (id INTEGER PRIMARY KEY, '
        'name TEXT, sort_order INTEGER)');
    await corpus.execute('CREATE TABLE traditions (id INTEGER PRIMARY KEY, '
        'name TEXT, branch_id INTEGER, sort_order INTEGER)');
    await corpus.execute('CREATE TABLE source_types (id INTEGER PRIMARY KEY, '
        'name TEXT)');
    await corpus.execute('CREATE TABLE sources (id INTEGER PRIMARY KEY, '
        'title TEXT, author TEXT, date_composed TEXT, source_url TEXT, '
        'license TEXT, tradition_id INTEGER, source_type_id INTEGER)');
    await corpus.execute('CREATE TABLE content_units (id INTEGER PRIMARY KEY, '
        'source_id INTEGER, sequence INTEGER, title TEXT, unit_number INTEGER, '
        'unit_type TEXT, content TEXT)');
    await corpus.execute('CREATE VIRTUAL TABLE content_fts USING fts5('
        'content, title, content=content_units, content_rowid=id)');
    await PackService.createTables(corpus);

    // Three branches whose taxonomy order is the reverse of their alphabetical
    // order, and inside the last one two families likewise reversed.
    await corpus.insert('branches',
        {'id': 1, 'name': 'The Undivided Church', 'sort_order': 1});
    await corpus.insert(
        'branches', {'id': 2, 'name': 'Eastern Orthodox', 'sort_order': 4});
    await corpus
        .insert('branches', {'id': 3, 'name': 'Protestant', 'sort_order': 6});

    await corpus.insert('traditions',
        {'id': 1, 'name': 'Scripture', 'branch_id': 1, 'sort_order': 1});
    // Same name as its branch: the shelf must not print the heading twice.
    await corpus.insert('traditions',
        {'id': 2, 'name': 'Eastern Orthodox', 'branch_id': 2, 'sort_order': 1});
    await corpus.insert('traditions',
        {'id': 3, 'name': 'Lutheran', 'branch_id': 3, 'sort_order': 1});
    await corpus.insert('traditions',
        {'id': 4, 'name': 'Adventist', 'branch_id': 3, 'sort_order': 11});

    var sourceId = 10;
    for (final tradition in [1, 2, 3, 4]) {
      await corpus.insert('sources', {
        'id': sourceId,
        'title': 'A work in tradition $tradition',
        'author': 'An author',
        'date_composed': '1600',
        'tradition_id': tradition,
      });
      await corpus.insert('content_units', {
        'id': 900 + sourceId,
        'source_id': sourceId,
        'sequence': 1,
        'title': 'A unit',
        'unit_type': 'article',
        'content': 'Some text.',
      });
      sourceId++;
    }

    userDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(userDb);
    db = DatabaseService()..useForTesting(corpus);

    final catalogue = await PackCatalogue.load();
    packs = PackProvider(PackService(corpus), catalogue);
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await corpus.close();
    await userDb.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> showShelf(WidgetTester tester) async {
    // Tall enough that every heading is laid out without scrolling, since what
    // is being asserted is the order they appear in.
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider()),
        ChangeNotifierProvider<InferenceProvider>(
            create: (_) => InferenceProvider()),
        ChangeNotifierProvider<PackProvider>.value(value: packs),
      ],
      child: const MaterialApp(home: ReadScreen()),
    ));
    await settle(tester);
  }

  /// Where a piece of text sits down the screen, so headings can be compared
  /// to one another rather than to a hard-coded offset.
  double topOf(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  testWidgets('branches head their traditions, in taxonomy order',
      (tester) async {
    await showShelf(tester);

    // Branch headings are drawn in caps; family headings keep their case.
    expect(find.text('THE UNDIVIDED CHURCH'), findsOneWidget);
    expect(find.text('PROTESTANT'), findsOneWidget);

    expect(topOf(tester, 'THE UNDIVIDED CHURCH'),
        lessThan(topOf(tester, 'PROTESTANT')));
    // Eastern Orthodox sorts before Protestant by name as well as by taxonomy,
    // so the pair that proves the ordering is this one: 'The Undivided Church'
    // comes first despite starting with T.
    expect(topOf(tester, 'Scripture'), lessThan(topOf(tester, 'PROTESTANT')));
  });

  testWidgets('families run in taxonomy order inside a branch',
      (tester) async {
    await showShelf(tester);
    // Lutheran (sort 1) above Adventist (sort 11), which is the reverse of
    // alphabetical and the whole reason the ordering is not by name.
    expect(topOf(tester, 'Lutheran'), lessThan(topOf(tester, 'Adventist')));
  });

  testWidgets('a branch holding only its namesake prints one heading',
      (tester) async {
    await showShelf(tester);
    // The family heading survives — it carries the count and the chevron — and
    // the branch heading above it is suppressed rather than repeating it.
    expect(find.text('Eastern Orthodox'), findsOneWidget);
    expect(find.text('EASTERN ORTHODOX'), findsNothing);
  });
}

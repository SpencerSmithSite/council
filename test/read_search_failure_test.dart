import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/screens/read_screen.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/packs/pack_catalogue.dart';
import 'package:council/src/services/packs/pack_provider.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/services/user_database.dart';

/// A search that throws must not leave the Read tab spinning.
///
/// _search set _searching true and then awaited the query with no guard at all,
/// so any throw escaped as an unhandled async error and the flag stayed set: a
/// CircularProgressIndicator, no message, no way back, for the life of the app.
/// The throw was not hypothetical — an all-stopword question in capitals built
/// `WHY* OR NOT*`, which is an FTS5 syntax error — and this tab is the one place
/// a search result was not wrapped in anything.
///
/// The corpus here is missing content_fts, which is simply the cheapest way to
/// make the query throw; what is under test is the tab's behaviour when it does.
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
    await PackService.createTables(corpus);
    await corpus.insert('sources', {'id': 1, 'title': 'The Confessions'});

    userDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(userDb);

    db = DatabaseService()..useForTesting(corpus);
    packs = PackProvider(PackService(corpus), await PackCatalogue.load());
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await corpus.close();
    await userDb.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  testWidgets('a failed search says so instead of spinning forever',
      (tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
        ChangeNotifierProvider<PackProvider>.value(value: packs),
      ],
      child: const MaterialApp(home: ReadScreen()),
    ));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, 'baptism');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the spinner has to stop even when the query throws');
    expect(find.textContaining('Something went wrong searching'), findsOneWidget,
        reason: 'and the reader is owed a sentence about it');
    // Not the empty-library message: offering to browse collections is the
    // wrong thing to say about a query that never ran.
    expect(find.text('Browse collections'), findsNothing);
  });
}

import 'dart:convert';

import 'package:council/src/screens/chat_screen.dart';
import 'package:council/src/screens/library_screen.dart';
import 'package:council/src/screens/read_screen.dart';
import 'package:council/src/services/chat_history_service.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/inference/inference_provider.dart';
import 'package:council/src/services/packs/pack_catalogue.dart';
import 'package:council/src/services/packs/pack_provider.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The three primary screens at the widths phones actually have.
///
/// The coverage notice overflowed by 25 px on an iPhone 17 because a `Row`
/// held two buttons whose labels interpolate a collection name and a byte
/// count. That shape is not unique to it — nearly every row in this app mixes
/// fixed chrome with text of unknown length, and a debug run on a desktop
/// window never shows which of them break. Ask, Read and Library are all here
/// for that reason.
///
/// Nothing here asserts a layout. An overflow *is* the failure: Flutter throws
/// during paint, which fails the test that pumped it. So the work is in
/// getting real text of hostile length onto the screen at 320 logical pixels —
/// the narrowest display Council supports, an iPhone SE.
void main() {
  late Database corpus;
  late Database userDb;
  late DatabaseService db;
  late PackProvider packs;

  /// A source title of the length the corpus actually holds. Council's longest
  /// run to about this, and they are what a citation row has to fit around.
  const longSource = 'The Nicene and Post-Nicene Fathers, Series II, '
      'Volume XIV: The Seven Ecumenical Councils';

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
    // The real index, not a stand-in: Read's search runs FTS5 MATCH, and a
    // fallback that only triggers on an empty result would never be reached.
    await corpus.execute('CREATE VIRTUAL TABLE content_fts USING fts5('
        'content, title, content=content_units, content_rowid=id)');
    await PackService.createTables(corpus);

    // A shelf of works whose names are the length the corpus actually holds,
    // filed under the longest tradition name in it.
    await corpus
        .insert('traditions', {'id': 1, 'name': 'Reformed and Presbyterian'});
    for (var i = 0; i < 4; i++) {
      await corpus.insert('sources', {
        'id': 10 + i,
        'title': '$longSource, part ${i + 1}',
        'author': 'Philip Schaff and Henry Wace, editors',
        'date_composed': '1890',
        'tradition_id': 1,
      });
      await corpus.insert('content_units', {
        'id': 900 + i,
        'source_id': 10 + i,
        'sequence': 1,
        'title': 'Canon ${i + 1} of the Council of Chalcedon',
        'unit_type': 'canon',
        'content': 'Baptism and the eucharist, treated at length by the '
            'council in its fourth session.',
      });
      await corpus.rawInsert(
        'INSERT INTO content_fts(rowid, content, title) VALUES (?, ?, ?)',
        [
          900 + i,
          'Baptism and the eucharist, treated at length by the council in '
              'its fourth session.',
          'Canon ${i + 1} of the Council of Chalcedon',
        ],
      );
    }

    userDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(userDb);

    db = DatabaseService()..useForTesting(corpus);

    // A catalogue with a manifest behind it, because the labels that break are
    // the ones carrying a byte count — "Add Nicene & Post-Nicene Writers ·
    // 96 MB" is the string the notice and the library both have to fit, and
    // without a manifest neither shows a size at all.
    final catalogue = await PackCatalogue.load();
    packs = PackProvider(
      PackService(
        corpus,
        client: MockClient(
          (_) async => http.Response(_manifestFor(catalogue), 200),
        ),
      ),
      catalogue,
    );
    await packs.refresh();
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await corpus.close();
    await userDb.close();
  });

  /// A thread with everything on it that has to fit: a pinned passage, a
  /// question, and an answer citing three works with long names.
  Future<int> seedConversation({PinnedPassage? passage}) async {
    final history = ChatHistoryService();
    final conversation = await history.createConversation(
      title: 'What does the church teach about baptism?',
      passage: passage,
    );
    await history.addMessage(
      conversationId: conversation.id,
      isUser: true,
      text: 'What did the councils and the confessions teach about the '
          'efficacy of baptism, and where do they disagree?',
    );
    await history.addMessage(
      conversationId: conversation.id,
      isUser: false,
      generated: true,
      text: 'The Westminster divines hold that the efficacy of baptism is not '
          'tied to the moment of administration [1], while the councils speak '
          'to its necessity [2].',
      citations: [
        for (var i = 0; i < 3; i++)
          {
            'contentId': 501 + i,
            'source': longSource,
            'author': 'The Synod of Constantinople under Nectarius',
            'tradition': 'Eastern Orthodox',
            'sourceUrl': 'https://en.wikisource.org/wiki/'
                'Nicene_and_Post-Nicene_Fathers_Series_II_Volume_XIV',
          },
      ],
    );
    return conversation.id;
  }

  /// The real event loop, so the screen's queries finish — see
  /// `citation_to_source_test.dart`.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Drag the length of a list, pumping as it goes.
  ///
  /// A `ListView` lays out what it paints, so a name that breaks the layout
  /// twenty rows down never gets the chance to until it is scrolled to.
  Future<void> scrollThrough(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pump();
    }
    await settle(tester);
  }

  Future<void> show(
    WidgetTester tester,
    Widget screen, {
    double textScale = 1.0,
  }) async {
    // 320 x 568 at a device pixel ratio of 1: an iPhone SE, the narrowest
    // display Council supports. Set before the first pump, so nothing lays
    // itself out at the default 800 x 600 test window first.
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
        ChangeNotifierProvider<InferenceProvider>(
          create: (_) => InferenceProvider(),
        ),
        ChangeNotifierProvider<PackProvider>.value(value: packs),
      ],
      child: MaterialApp(
        // The font-size preference reaches every screen this way and no other,
        // so a test that skips it is testing a configuration no reader has.
        // See `TheologyApp.build`.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ));

    await settle(tester);
  }

  Future<void> showAsk(
    WidgetTester tester, {
    int? conversationId,
    double textScale = 1.0,
  }) =>
      show(tester, ChatScreen(conversationId: conversationId),
          textScale: textScale);

  testWidgets('an empty Ask tab fits a 320 px phone', (tester) async {
    await showAsk(tester);
  });

  testWidgets('a cited answer fits a 320 px phone', (tester) async {
    final id = await tester.runAsync(seedConversation);

    await showAsk(tester, conversationId: id);

    // Proof the hostile content actually rendered — an overflow test that
    // silently laid out an empty screen would pass for the wrong reason.
    expect(find.textContaining('efficacy of baptism'), findsWidgets);
  });

  testWidgets('a passage-anchored thread fits a 320 px phone', (tester) async {
    final id = await tester.runAsync(() => seedConversation(
          passage: const PinnedPassage(
            contentUnitId: 503,
            quote: 'THE efficacy of baptism is not tied to that moment of '
                'time wherein it is administred.',
            reference: 'Chapter XXVIII, paragraph 6, of Baptism',
            sourceTitle: longSource,
          ),
        ));

    await showAsk(tester, conversationId: id);

    expect(find.textContaining('Chapter XXVIII'), findsWidgets);
  });

  // 1.5x is the top of the font-size slider, and 320 px is the narrowest
  // display — a reader with poor eyesight on an old phone is one person, not
  // two hypothetical ones, and this is the combination they get.
  testWidgets('a cited answer fits at the largest font size', (tester) async {
    final id = await tester.runAsync(seedConversation);

    await showAsk(tester, conversationId: id, textScale: 1.5);

    expect(find.textContaining('efficacy of baptism'), findsWidgets);
  });

  testWidgets('a passage-anchored thread fits at the largest font size',
      (tester) async {
    final id = await tester.runAsync(() => seedConversation(
          passage: const PinnedPassage(
            contentUnitId: 503,
            quote: 'THE efficacy of baptism is not tied to that moment of '
                'time wherein it is administred.',
            reference: 'Chapter XXVIII, paragraph 6, of Baptism',
            sourceTitle: longSource,
          ),
        ));

    await showAsk(tester, conversationId: id, textScale: 1.5);

    expect(find.textContaining('Chapter XXVIII'), findsWidgets);
  });

  /// The row with a history: its two buttons interpolate a collection name and
  /// a byte count, which is how it overflowed by 25 px on an iPhone 17.
  ///
  /// Reached the only way it can be — by asking a question, since the gaps are
  /// computed from the question rather than from what retrieval returned.
  /// Retrieval itself fails here (this corpus has no FTS index), which is
  /// immaterial: the notice is worked out before retrieval runs, and the error
  /// path renders the same row.
  Future<void> askAQuestion(WidgetTester tester, double textScale) async {
    await showAsk(tester, textScale: textScale);

    await tester.enterText(
      find.byType(TextField),
      'What do the Eastern Orthodox and the Church Fathers teach about the '
      'eucharist and baptism?',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // Nothing is installed in this database, so a question naming two
    // collections has to produce a notice — if it stops doing so, this test is
    // no longer looking at the row it claims to.
    expect(find.text('Browse library'), findsOneWidget);
    expect(find.textContaining('Add '), findsWidgets);
  }

  testWidgets('the coverage notice fits a 320 px phone', (tester) async {
    await askAQuestion(tester, 1.0);
  });

  testWidgets('the coverage notice fits at the largest font size',
      (tester) async {
    await askAQuestion(tester, 1.5);
  });

  // ---- Read -------------------------------------------------------------

  /// Sections start collapsed, so a test that only pumps the shelf renders
  /// headings and no works at all — and would pass without ever laying out the
  /// row it is here to check.
  Future<void> openTheShelf(WidgetTester tester, double textScale) async {
    await show(tester, const ReadScreen(), textScale: textScale);
    await tester.tap(find.text('Reformed and Presbyterian'));
    await settle(tester);
    expect(find.textContaining('Seven Ecumenical Councils'), findsWidgets);
  }

  testWidgets('the shelf fits a 320 px phone', (tester) async {
    await openTheShelf(tester, 1.0);
  });

  testWidgets('the shelf fits at the largest font size', (tester) async {
    await openTheShelf(tester, 1.5);
    await scrollThrough(tester);
  });

  /// Search results are a different surface from the shelf — a passage title
  /// and its source, rather than a work and its author — and they are reached
  /// through the same box that filters the shelf.
  testWidgets('search results fit at the largest font size', (tester) async {
    await show(tester, const ReadScreen(), textScale: 1.5);

    await tester.enterText(find.byType(TextField), 'eucharist');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.textContaining('Chalcedon'), findsWidgets);
  });

  // ---- Library ----------------------------------------------------------

  testWidgets('the library fits a 320 px phone', (tester) async {
    await show(tester, const LibraryScreen(embedded: true));

    // The manifest resolved, so the rows carry the download sizes that are the
    // whole reason these labels are long.
    expect(find.textContaining('MB'), findsWidgets);
  });

  testWidgets('the library fits at the largest font size', (tester) async {
    await show(tester, const LibraryScreen(embedded: true), textScale: 1.5);

    expect(find.textContaining('MB'), findsWidgets);
    // Every collection in the real catalogue, not just the handful above the
    // fold: a list only lays out what it paints, so the row with the longest
    // name in it is reached by scrolling or not at all.
    await scrollThrough(tester);
  });

  testWidgets('the pushed library fits at the largest font size',
      (tester) async {
    // Pushed rather than embedded: it paints its own background and carries a
    // back button, so its top row is not the one tested above.
    await show(tester, const LibraryScreen(), textScale: 1.5);

    expect(find.textContaining('MB'), findsWidgets);
  });
}

/// A manifest for every collection the bundled catalogue describes.
///
/// Built from the catalogue rather than written out here so the names under
/// test are the real ones — "Nicene & Post-Nicene Writers" is longer than
/// anything a fixture would invent, and the length is the point. The sizes are
/// uniform and deliberately large: what matters is that every row renders a
/// two- or three-digit megabyte count beside its name.
String _manifestFor(PackCatalogue catalogue) {
  final fragments = <String>{
    for (final pack in catalogue.packs.values) ...pack.fragments,
  };

  return jsonEncode({
    'corpusVersion': 15,
    'idSpace': 1,
    'fragments': [
      for (final id in fragments)
        {
          'id': id,
          'file': '\$id.db.gz',
          'bytes': 24 * 1024 * 1024,
          'sha256': 'not verified here',
          'sources': 12,
          'units': 3400,
          'chunks': 9100,
        },
    ],
    'collections': [
      for (final entry in catalogue.packs.entries)
        {
          'id': entry.key,
          'name': entry.value.name,
          'description': 'Everything this collection holds, described at the '
              'length the real catalogue describes it.',
          'kind': 'tradition',
          'fragments': entry.value.fragments,
        },
    ],
  });
}

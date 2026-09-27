import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:council/src/screens/chat_screen.dart';
import 'package:council/src/services/chat_history_service.dart';
import 'package:council/src/services/database_service.dart';
import 'package:council/src/services/inference/inference_backend.dart';
import 'package:council/src/services/inference/inference_provider.dart';
import 'package:council/src/services/packs/pack_catalogue.dart';
import 'package:council/src/services/packs/pack_provider.dart';
import 'package:council/src/services/packs/pack_service.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/theme/glass_controls.dart';
import 'package:council/src/services/user_database.dart';

/// What happens to a transcript when an answer does not simply arrive.
///
/// The three failures pinned here were all reachable from the Ask tab with
/// nothing more exotic than a flaky network, and none of them was reachable
/// from a test, because there was no way to hand the screen a backend whose
/// timing a test controls. That seam is [InferenceProvider.useBackendForTesting].
///
/// * Stop could not stop. It set a flag the streaming loop read *between*
///   chunks, so a backend that accepted the request and then went quiet left the
///   loop parked forever — and Stop disables itself when pressed, while the
///   composer stays disabled until the stream ends. The screen was dead.
/// * An answer that failed before its first token left an empty bubble behind,
///   carrying citation tiles, above the error message. Reopening the thread from
///   history then showed something different, because empty text is not stored.
/// * Starting a new thread mid-answer threw RangeError on a transcript that had
///   just been cleared, and the error was caught, formatted and persisted into
///   the new thread as the assistant's opening words.
class _ScriptedBackend implements InferenceBackend {
  _ScriptedBackend(this.controller);

  final StreamController<String> controller;

  @override
  String get id => 'scripted';
  @override
  String get displayName => 'Scripted';
  @override
  String get description => 'A backend a test drives by hand.';
  @override
  bool get isPrivate => true;
  @override
  int get contextBudgetChars => 4000;
  @override
  Future<BackendStatus> checkStatus() async => const BackendStatus.available();
  @override
  Stream<String> generate({required String prompt, String? system}) =>
      controller.stream;
  @override
  Future<List<String>> availableModels() async => const [];
  @override
  void dispose() {}
}

void main() {
  late Database corpus;
  late Database userDb;
  late DatabaseService db;
  late PackProvider packs;
  late StreamController<String> tokens;
  late InferenceProvider inference;

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
    // Retrieval fuses an FTS ranking with a tag ranking, so both tables have to
    // exist or searchForRAG throws before the backend is ever reached.
    await corpus.execute('CREATE TABLE tags (id INTEGER PRIMARY KEY, '
        'slug TEXT, name TEXT)');
    await corpus.execute('CREATE TABLE content_tags ('
        'content_unit_id INTEGER, tag_id INTEGER)');
    await corpus.execute('CREATE TABLE content_chunks (id INTEGER PRIMARY KEY, '
        'content_unit_id INTEGER, sequence INTEGER, char_start INTEGER, '
        'char_end INTEGER)');
    await corpus.execute('CREATE TABLE chunk_embeddings ('
        'chunk_id INTEGER PRIMARY KEY, vector BLOB)');
    await PackService.createTables(corpus);

    await corpus.insert('sources', {'id': 1, 'title': 'The Confessions'});
    await corpus.insert('content_units', {
      'id': 90,
      'source_id': 1,
      'sequence': 1,
      'title': 'Book I',
      'content': 'Baptism is treated here at some length.',
    });
    await corpus.rawInsert(
      'INSERT INTO content_fts(rowid, content, title) VALUES (?, ?, ?)',
      [90, 'Baptism is treated here at some length.', 'Book I'],
    );

    userDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(userDb);

    db = DatabaseService()..useForTesting(corpus);
    packs = PackProvider(PackService(corpus), await PackCatalogue.load());

    tokens = StreamController<String>();
    inference = InferenceProvider()
      ..useBackendForTesting(_ScriptedBackend(tokens));
  });

  tearDown(() async {
    if (!tokens.isClosed) await tokens.close();
    UserDatabase.resetForTesting();
    await corpus.close();
    await userDb.close();
  });

  /// The real event loop, so the screen's database queries finish.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  final key = GlobalKey<ChatScreenState>();

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
        ChangeNotifierProvider<InferenceProvider>.value(value: inference),
        ChangeNotifierProvider<PackProvider>.value(value: packs),
      ],
      // A pinned passage, so the transcript never depends on retrieval finding
      // anything: what is under test is what happens to the answer, not how the
      // sources for it were chosen.
      child: MaterialApp(
        home: ChatScreen(
          key: key,
          passage: const PinnedPassage(
            contentUnitId: 90,
            quote: 'Baptism is treated here at some length.',
            reference: 'Book I',
            sourceTitle: 'The Confessions',
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  /// Ask a question the way a reader does: type it, tap send.
  Future<void> ask(WidgetTester tester, String question) async {
    await tester.enterText(find.byType(TextField).first, question);
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await settle(tester);
  }

  testWidgets('Stop ends an answer that has gone quiet', (tester) async {
    await show(tester);
    await ask(tester, 'What is baptism?');

    tokens.add('Baptism is');
    await settle(tester);
    expect(find.text('Stop'), findsOneWidget,
        reason: 'the answer is still streaming');

    // The backend now says nothing further, and never closes the stream — a
    // provider that has accepted the request and stalled.
    await tester.tap(find.text('Stop'));
    await settle(tester);

    // The composer is usable again. Before the fix this waited on a token that
    // was never coming, and the screen stayed locked for the life of the app.
    expect(find.text('Stop'), findsNothing);
    final composer = tester.widget<TextField>(find.byType(TextField).first);
    expect(composer.enabled, isTrue);
    expect(find.textContaining('Baptism is'), findsWidgets,
        reason: 'what did arrive before stopping is kept');
  });

  testWidgets('an answer that fails before its first token leaves no empty '
      'bubble', (tester) async {
    await show(tester);
    await ask(tester, 'What is baptism?');

    tokens.addError(InferenceException(
        'Claude did not respond within a minute. Check your connection and '
        'try again.'));
    await settle(tester);

    expect(find.textContaining('did not respond within a minute'),
        findsOneWidget);

    // The placeholder bubble carries the citation tiles, because the sources are
    // known before the first token is. So a stray "Sources:" block is the
    // orphaned bubble made visible: an answer that never said anything is
    // offering a bibliography for it.
    expect(find.text('Sources:'), findsNothing,
        reason: 'an answer that failed before saying anything has nothing to '
            'cite');

    // And the screen agrees with the store. It could not before: _persist skips
    // empty text, so the empty bubble was on screen and absent from history, and
    // reopening the thread showed a different transcript. Read through runAsync
    // — sqflite needs the real clock, not the fake one a widget test pumps.
    final assistantMessages = (await tester.runAsync(() async {
      final history = ChatHistoryService();
      final threads = await history.conversations();
      final messages = await history.messages(threads.single.id);
      return messages.where((m) => !m.isUser).toList();
    }))!;
    expect(assistantMessages, hasLength(1));
    expect(assistantMessages.single.text,
        contains('did not respond within a minute'));
  });

  testWidgets('starting a new thread mid-answer does not write an error into '
      'it', (tester) async {
    await show(tester);
    await ask(tester, 'What is baptism?');

    tokens.add('Baptism is the sign');
    await settle(tester);

    // The compose button on the main screen drives this, and it has no loading
    // guard: it is reachable while an answer is streaming.
    await tester.runAsync(() => key.currentState!.startNewConversation());
    await settle(tester);

    expect(find.textContaining('RangeError'), findsNothing);
    expect(find.textContaining('Error:'), findsNothing);
    expect(find.textContaining('Baptism is the sign'), findsNothing,
        reason: 'the new thread is empty');

    // And the partial answer stayed with the thread it was asked in, rather
    // than following the reader into the new one.
    final stored = (await tester.runAsync(() async {
      final history = ChatHistoryService();
      final threads = await history.conversations();
      final messages = await history.messages(threads.single.id);
      return messages.map((m) => m.text).toList();
    }))!;
    expect(stored, everyElement(isNot(contains('RangeError'))));
    expect(stored.any((t) => t.contains('Baptism is the sign')), isTrue,
        reason: 'what was generated belongs to the thread it was asked in');
  });
}

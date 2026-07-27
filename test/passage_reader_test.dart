import 'package:council/src/reader/passage_action_bar.dart';
import 'package:council/src/reader/passage_reader.dart';
import 'package:council/src/screens/chat_history_screen.dart';
import 'package:council/src/screens/notes_screen.dart';
import 'package:council/src/services/annotation_service.dart';
import 'package:council/src/services/chat_history_service.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Selecting verses and acting on them, driven through the real widget.
///
/// The interesting failures here are not in the segmentation — that has its
/// own suite — but in the wiring: that a tap reaches the right verse, that the
/// toolbar appears and goes away again, and that choosing a colour writes
/// something that is still there when the passage is opened next.
void main() {
  late Database db;
  late AnnotationService annotations;

  const genesis = '1. In the beginning God created the heaven and the earth.\n'
      '2. And the earth was without form, and void.\n'
      '3. And God said, Let there be light: and there was light.\n';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await UserDatabase.useForTesting(db);
    annotations = AnnotationService();
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await db.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PassageReader(
            contentUnitId: 23558,
            content: genesis,
            unitTitle: 'Genesis 1',
            sourceTitle: 'The Holy Bible: King James Version',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapVerse(WidgetTester tester, String fragment) async {
    await tester.tapOnText(find.textRange.ofSubstring(fragment));
    await tester.pumpAndSettle();
  }

  /// Let a database read or write that the widget started actually run.
  ///
  /// `testWidgets` drives a fake clock, and sqflite's work completes on the
  /// real event loop — so without turning the real loop here, every query the
  /// UI kicks off simply never finishes and the test hangs rather than fails.
  ///
  /// Alternated rather than done once, because a screen typically issues
  /// several queries in turn and each one's `setState` only lands on the next
  /// pump — and pumped a fixed number of frames rather than settled, because a
  /// screen that is still loading is showing a spinner, and a spinner never
  /// settles.
  Future<void> settleDatabase(WidgetTester tester) async {
    for (var round = 0; round < 6; round++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('no toolbar until something is selected', (tester) async {
    await open(tester);
    expect(find.byType(PassageActionBar), findsNothing);
  });

  testWidgets('tapping a verse raises the toolbar', (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');

    expect(find.byType(PassageActionBar), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('tapping a second verse extends the selection', (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');
    await tapVerse(tester, 'without form');

    expect(
      tester.widget<PassageActionBar>(find.byType(PassageActionBar)).count,
      2,
    );
    expect(
      tester.widget<PassageActionBar>(find.byType(PassageActionBar)).noun,
      'verses',
    );
  });

  testWidgets('tapping a selected verse again deselects it', (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');
    await tapVerse(tester, 'In the beginning');

    expect(find.byType(PassageActionBar), findsNothing);
  });

  testWidgets('dismissing clears the selection', (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(PassageActionBar), findsNothing);
  });

  testWidgets('the toolbar gets out of the way of the colour sheet',
      (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');

    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();

    // The toolbar lives in the overlay, above every route, so if it is still
    // built while the sheet is up it is sitting on top of the swatches.
    expect(find.text('Highlight 1 verse'), findsOneWidget);
    expect(find.byType(PassageActionBar), findsNothing);

    // Backing out of the sheet leaves the selection, so the toolbar returns.
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();
    expect(find.byType(PassageActionBar), findsOneWidget);
  });

  testWidgets('choosing a colour writes a highlight over what was picked',
      (tester) async {
    await open(tester);
    await tapVerse(tester, 'In the beginning');
    await tapVerse(tester, 'without form');

    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('highlight-swatch-yellow')));
    await settleDatabase(tester);

    final stored =
        await tester.runAsync(() => annotations.highlightsFor(23558));
    expect(stored, hasLength(1));
    expect(stored!.single.colour, 'yellow');
    expect(stored.single.reference, 'Genesis 1:1, 2');
    expect(
      stored.single.quote,
      'In the beginning God created the heaven and the earth. '
      'And the earth was without form, and void.',
    );

    // Acting on the selection also ends it.
    expect(find.byType(PassageActionBar), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('the note button stores the quotation with its reference',
      (tester) async {
    await open(tester);
    await tapVerse(tester, 'Let there be light');

    await tester.tap(find.byIcon(Icons.sticky_note_2_outlined));
    await settleDatabase(tester);

    final notes = await tester.runAsync(() => annotations.allNotes());
    expect(notes, hasLength(1));
    expect(notes!.single.reference, 'Genesis 1:3');
    expect(notes.single.quote, startsWith('And God said'));
    expect(notes.single.sourceTitle, 'The Holy Bible: King James Version');
    // Opened straight into the editor, ready to be written in.
    expect(find.text('Your thoughts on this passage…'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('the lists these feed', () {
    testWidgets('Notes shows both kinds, newest first', (tester) async {
      await tester.runAsync(() async {
        await annotations.createNote(
          contentUnitId: 546,
          quote: 'We believe and confess…',
          body: 'Compare with Trent, session VI.',
          reference: 'Of the Holy Scripture',
          sourceTitle: 'Second Helvetic Confession',
        );
        await annotations.addHighlight(
          contentUnitId: 23558,
          charStart: 0,
          charEnd: 57,
          colour: 'green',
          quote: 'In the beginning God created the heaven and the earth.',
          reference: 'Genesis 1:1',
        );
      });

      await tester.pumpWidget(const MaterialApp(home: NotesScreen()));
      await settleDatabase(tester);

      expect(find.text('Compare with Trent, session VI.'), findsOneWidget);
      expect(find.textContaining('Of the Holy Scripture'), findsWidgets);

      await tester.tap(find.text('Highlights'));
      await tester.pumpAndSettle();
      expect(find.textContaining('In the beginning'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('Notes says what to do when there is nothing in it',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: NotesScreen()));
      await settleDatabase(tester);
      expect(find.text('No notes yet'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('Chat history lists a thread and hands its id back',
        (tester) async {
      final history = ChatHistoryService();
      final conversation = await tester.runAsync(() async {
        final created =
            await history.createConversation(title: 'What is grace?');
        await history.addMessage(
            conversationId: created.id, isUser: true, text: 'What is grace?');
        await history.addMessage(
            conversationId: created.id,
            isUser: false,
            text: 'Augustine calls it prevenient.');
        return created;
      });

      int? chosen;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await Navigator.push<int>(
                context,
                MaterialPageRoute(builder: (_) => const ChatHistoryScreen()),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settleDatabase(tester);

      expect(find.text('What is grace?'), findsOneWidget);
      expect(find.text('Augustine calls it prevenient.'), findsOneWidget);

      await tester.tap(find.text('What is grace?'));
      await tester.pumpAndSettle();
      // Handed back rather than opened here, so the Ask tab owns the thread.
      expect(chosen, conversation!.id);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

import 'package:council/src/services/annotation_service.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Highlights and notes, against a real SQLite.
///
/// In memory rather than on disk, but the same engine and the same schema the
/// app ships — which is the point: this is the layer that has to survive the
/// app being closed, and testing it against a stand-in would prove nothing
/// about that.
void main() {
  late Database db;
  late AnnotationService annotations;

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

  group('highlights', () {
    Future<void> mark(int start, int end, String colour) => annotations
        .addHighlight(
          contentUnitId: 23558,
          charStart: start,
          charEnd: end,
          colour: colour,
          quote: 'In the beginning',
          unitTitle: 'Genesis 1',
          reference: 'Genesis 1:1',
        )
        .then((_) {});

    test('round-trips', () async {
      await mark(0, 57, 'yellow');
      final stored = await annotations.highlightsFor(23558);
      expect(stored, hasLength(1));
      expect(stored.single.colour, 'yellow');
      expect(stored.single.reference, 'Genesis 1:1');
    });

    test('re-colouring replaces rather than layers', () async {
      // Two colours over one verse has no meaning the reader could act on, and
      // leaving the old row would grow the file on every change of mind.
      await mark(0, 57, 'yellow');
      await mark(0, 57, 'green');

      final stored = await annotations.highlightsFor(23558);
      expect(stored, hasLength(1));
      expect(stored.single.colour, 'green');
    });

    test('an overlapping mark clears what it covers', () async {
      await mark(0, 57, 'yellow');
      await mark(40, 120, 'blue');

      final stored = await annotations.highlightsFor(23558);
      expect(stored, hasLength(1));
      expect(stored.single.charStart, 40);
    });

    test('a mark that does not overlap is left alone', () async {
      await mark(0, 57, 'yellow');
      await mark(100, 160, 'blue');
      expect(await annotations.highlightsFor(23558), hasLength(2));
    });

    test('removal is by range, not by id', () async {
      await mark(0, 57, 'yellow');
      final removed = await annotations.removeHighlightsIn(
          contentUnitId: 23558, charStart: 10, charEnd: 20);
      expect(removed, 1);
      expect(await annotations.highlightsFor(23558), isEmpty);
    });

    test('highlights are scoped to their passage', () async {
      await mark(0, 57, 'yellow');
      expect(await annotations.highlightsFor(99999), isEmpty);
    });
  });

  group('notes', () {
    test('newest first, by when they were last written in', () async {
      final first = await annotations.createNote(
          contentUnitId: 1, body: 'first', quote: 'a');
      await annotations.createNote(
          contentUnitId: 2, body: 'second', quote: 'b');

      // Coming back to an older note makes it live again; it should not stay
      // buried under something merely created more recently.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await annotations.updateNoteBody(first.id, 'first, revisited');

      final notes = await annotations.allNotes();
      expect(notes.map((n) => n.body).toList(),
          ['first, revisited', 'second']);
    });

    test('the quotation survives editing the body', () async {
      final note = await annotations.createNote(
        contentUnitId: 546,
        quote: 'We believe and confess…',
        reference: 'Of the Holy Scripture',
        body: '',
      );
      await annotations.updateNoteBody(note.id, 'Compare with Trent.');

      final stored = (await annotations.notesFor(546)).single;
      expect(stored.quote, 'We believe and confess…');
      expect(stored.body, 'Compare with Trent.');
      expect(stored.reference, 'Of the Holy Scripture');
    });

    test('deleting one leaves the rest', () async {
      final note = await annotations.createNote(body: 'gone');
      await annotations.createNote(body: 'kept');
      await annotations.deleteNote(note.id);

      expect(await annotations.countNotes(), 1);
      expect((await annotations.allNotes()).single.body, 'kept');
    });
  });
}

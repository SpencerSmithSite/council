import 'package:sqflite/sqflite.dart';

import 'user_database.dart';

/// A stretch of a passage the reader has marked.
class Highlight {
  final int id;
  final int contentUnitId;
  final int charStart;
  final int charEnd;

  /// A [HighlightColour] id. Held as a string so the service layer carries no
  /// dependency on Flutter's painting library.
  final String colour;

  final String quote;
  final String? sourceTitle;
  final String? unitTitle;
  final String? reference;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Highlight({
    required this.id,
    required this.contentUnitId,
    required this.charStart,
    required this.charEnd,
    required this.colour,
    required this.quote,
    this.sourceTitle,
    this.unitTitle,
    this.reference,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Highlight.fromRow(Map<String, Object?> row) => Highlight(
        id: row['id'] as int,
        contentUnitId: row['content_unit_id'] as int,
        charStart: row['char_start'] as int,
        charEnd: row['char_end'] as int,
        colour: row['colour'] as String,
        quote: row['quote'] as String,
        sourceTitle: row['source_title'] as String?,
        unitTitle: row['unit_title'] as String?,
        reference: row['reference'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  bool overlaps(int start, int end) => charStart < end && start < charEnd;
}

/// A passage the reader wanted to write about, and what they wrote.
///
/// [quote] and [body] are separate because they answer to different owners: the
/// quote is the corpus's words and must not be edited, the body is the
/// reader's. A note may also stand alone — [contentUnitId] null — though
/// nothing in the app creates one that way yet.
class Note {
  final int id;
  final int? contentUnitId;
  final int? charStart;
  final int? charEnd;
  final String? quote;
  final String body;
  final String? sourceTitle;
  final String? unitTitle;
  final String? reference;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Note({
    required this.id,
    this.contentUnitId,
    this.charStart,
    this.charEnd,
    this.quote,
    required this.body,
    this.sourceTitle,
    this.unitTitle,
    this.reference,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromRow(Map<String, Object?> row) => Note(
        id: row['id'] as int,
        contentUnitId: row['content_unit_id'] as int?,
        charStart: row['char_start'] as int?,
        charEnd: row['char_end'] as int?,
        quote: row['quote'] as String?,
        body: row['body'] as String,
        sourceTitle: row['source_title'] as String?,
        unitTitle: row['unit_title'] as String?,
        reference: row['reference'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
}

/// Reads and writes the reader's highlights and notes.
///
/// Constructed freely wherever it is needed — it holds no state of its own and
/// the underlying connection is shared by [UserDatabase].
class AnnotationService {
  Future<Database> get _db async => UserDatabase.open();

  // ---------------------------------------------------------------- highlights

  /// Every highlight on one passage, oldest first so that later marks paint
  /// over earlier ones where they overlap.
  Future<List<Highlight>> highlightsFor(int contentUnitId) async {
    final db = await _db;
    final rows = await db.query(
      'highlights',
      where: 'content_unit_id = ?',
      whereArgs: [contentUnitId],
      orderBy: 'char_start, id',
    );
    return rows.map(Highlight.fromRow).toList();
  }

  /// Every highlight, most recent first.
  Future<List<Highlight>> allHighlights({int limit = 500}) async {
    final db = await _db;
    final rows = await db.query('highlights',
        orderBy: 'created_at DESC, id DESC', limit: limit);
    return rows.map(Highlight.fromRow).toList();
  }

  /// Mark [charStart]–[charEnd] in [colour], replacing whatever was already
  /// marked there.
  ///
  /// Overlapping marks are removed rather than layered. Two colours over one
  /// verse has no meaning the reader could act on, and leaving the old row
  /// behind would make "highlight, change your mind, highlight again" grow the
  /// database without ever changing what is on screen.
  Future<Highlight> addHighlight({
    required int contentUnitId,
    required int charStart,
    required int charEnd,
    required String colour,
    required String quote,
    String? sourceTitle,
    String? unitTitle,
    String? reference,
  }) async {
    final db = await _db;
    final now = DateTime.now();

    await db.delete(
      'highlights',
      where: 'content_unit_id = ? AND char_start < ? AND ? < char_end',
      whereArgs: [contentUnitId, charEnd, charStart],
    );

    final id = await db.insert('highlights', {
      'content_unit_id': contentUnitId,
      'char_start': charStart,
      'char_end': charEnd,
      'colour': colour,
      'quote': quote,
      'source_title': sourceTitle,
      'unit_title': unitTitle,
      'reference': reference,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    return Highlight(
      id: id,
      contentUnitId: contentUnitId,
      charStart: charStart,
      charEnd: charEnd,
      colour: colour,
      quote: quote,
      sourceTitle: sourceTitle,
      unitTitle: unitTitle,
      reference: reference,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Clear any highlight touching [charStart]–[charEnd]. Returns how many went.
  Future<int> removeHighlightsIn({
    required int contentUnitId,
    required int charStart,
    required int charEnd,
  }) async {
    final db = await _db;
    return db.delete(
      'highlights',
      where: 'content_unit_id = ? AND char_start < ? AND ? < char_end',
      whereArgs: [contentUnitId, charEnd, charStart],
    );
  }

  Future<void> deleteHighlight(int id) async {
    final db = await _db;
    await db.delete('highlights', where: 'id = ?', whereArgs: [id]);
  }

  // --------------------------------------------------------------------- notes

  /// Every note, most recent first — which is the order the Notes screen shows
  /// them in, and the only order it offers.
  ///
  /// Ordered by [Note.updatedAt] rather than creation: a note the reader came
  /// back to and added a thought to is live again, and burying it under things
  /// merely created more recently would be wrong.
  Future<List<Note>> allNotes({int limit = 1000}) async {
    final db = await _db;
    final rows = await db.query('notes',
        orderBy: 'updated_at DESC, id DESC', limit: limit);
    return rows.map(Note.fromRow).toList();
  }

  Future<List<Note>> notesFor(int contentUnitId) async {
    final db = await _db;
    final rows = await db.query(
      'notes',
      where: 'content_unit_id = ?',
      whereArgs: [contentUnitId],
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(Note.fromRow).toList();
  }

  Future<int> countNotes() async {
    final db = await _db;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM notes')) ??
        0;
  }

  Future<Note> createNote({
    int? contentUnitId,
    int? charStart,
    int? charEnd,
    String? quote,
    String body = '',
    String? sourceTitle,
    String? unitTitle,
    String? reference,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final values = {
      'content_unit_id': contentUnitId,
      'char_start': charStart,
      'char_end': charEnd,
      'quote': quote,
      'body': body,
      'source_title': sourceTitle,
      'unit_title': unitTitle,
      'reference': reference,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    };
    final id = await db.insert('notes', values);
    return Note.fromRow({...values, 'id': id});
  }

  Future<void> updateNoteBody(int id, String body) async {
    final db = await _db;
    await db.update(
      'notes',
      {'body': body, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteNote(int id) async {
    final db = await _db;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}

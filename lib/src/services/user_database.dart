import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Everything the reader writes: highlights, notes, and conversations.
///
/// Deliberately *not* `theology.db`. That file is a shipped artefact —
/// `DatabaseService` deletes and reinstalls it wholesale whenever the bundled
/// corpus version changes, and content packs merge into it. A note stored
/// there would be destroyed by a routine content update, which is the one
/// thing a reader's own writing must never do.
///
/// One connection, opened once and shared, because sqflite hands out a
/// separate handle per `openDatabase` call and two handles to one file is how
/// a locked database happens.
class UserDatabase {
  static const String fileName = 'council_user.db';

  /// Bumped when the tables below change. [_upgrade] must then learn how to
  /// carry an existing file forward — this database is never reinstalled, so
  /// migration is the only path.
  static const int schemaVersion = 2;

  static Database? _db;
  static Future<Database>? _opening;

  /// The shared connection, opened on first use.
  static Future<Database> open() {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    return _opening ??= _open();
  }

  static Future<Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    final db = await openAt(p.join(dir.path, fileName));
    _db = db;
    return db;
  }

  /// Open (creating or migrating) the user database at an explicit path.
  ///
  /// Public so the migration can be tested against a database in the *old*
  /// shape. The alternative — trusting an `ALTER TABLE` that only ever runs on
  /// a real device — risks discovering a broken migration by destroying
  /// someone's notes.
  static Future<Database> openAt(String path) => openDatabase(
        path,
        version: schemaVersion,
        onCreate: (db, _) => _create(db),
        onUpgrade: _upgrade,
      );

  static Future<void> _create(Database db) async {
    // Highlights and notes are anchored by character offsets into a content
    // unit *and* carry the text they were taken from. The offsets are what
    // make rendering cheap; the text is what lets an annotation be re-found if
    // a corpus rebuild shifts the unit underneath it, and what lets a note
    // still show its quotation when the passage is gone entirely.
    await db.execute('''
      CREATE TABLE highlights (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_unit_id INTEGER NOT NULL,
        char_start INTEGER NOT NULL,
        char_end INTEGER NOT NULL,
        colour TEXT NOT NULL,
        quote TEXT NOT NULL,
        source_title TEXT,
        unit_title TEXT,
        reference TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_highlights_unit ON highlights(content_unit_id)');

    await db.execute('''
      CREATE TABLE notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_unit_id INTEGER,
        char_start INTEGER,
        char_end INTEGER,
        quote TEXT,
        body TEXT NOT NULL,
        source_title TEXT,
        unit_title TEXT,
        reference TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_notes_unit ON notes(content_unit_id)');

    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        passage_unit_id INTEGER,
        passage_quote TEXT,
        passage_reference TEXT,
        passage_source TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // `generated` marks a message a language model actually wrote, as opposed
    // to one the app composed itself — a retrieval-only result, an
    // unavailable-backend notice, an error. Only the former needs the
    // reliability caveat, and only the first one in a thread carries it.
    await db.execute('''
      CREATE TABLE conversation_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        is_user INTEGER NOT NULL,
        text TEXT NOT NULL,
        citations TEXT,
        generated INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_conversation '
        'ON conversation_messages(conversation_id, seq)');
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      // Existing assistant messages default to 0, so an old thread simply
      // shows no caveat rather than one attached to the wrong message.
      await db.execute('ALTER TABLE conversation_messages '
          'ADD COLUMN generated INTEGER NOT NULL DEFAULT 0');
    }
  }

  /// Point the shared connection at a database the caller opened.
  ///
  /// Tests use this with an in-memory database so the services can be
  /// exercised without a device file system.
  @visibleForTesting
  static Future<Database> useForTesting(Database db) async {
    _db = db;
    _opening = null;
    await _create(db);
    return db;
  }

  /// Adopt a connection that already has the tables — one opened by [openAt],
  /// so the services can be run against a migrated database.
  @visibleForTesting
  static void adoptForTesting(Database db) {
    _db = db;
    _opening = null;
  }

  @visibleForTesting
  static void resetForTesting() {
    _db = null;
    _opening = null;
  }
}

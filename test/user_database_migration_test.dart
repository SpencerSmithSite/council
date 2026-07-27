import 'dart:io';

import 'package:council/src/services/chat_history_service.dart';
import 'package:council/src/services/user_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Carrying an existing user database forward.
///
/// This file is never reinstalled — that is the whole reason it exists apart
/// from the corpus — so migration is the only path, and a broken one destroys
/// notes rather than merely failing. Exercised against a database built in the
/// genuinely old shape rather than against the current schema.
void main() {
  late Directory dir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('council-user-db');
  });

  tearDown(() async {
    UserDatabase.resetForTesting();
    await dir.delete(recursive: true);
  });

  /// The schema as version 1 shipped it: no `generated` column.
  Future<void> createVersion1(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
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
          await db.execute('''
            CREATE TABLE conversation_messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              conversation_id INTEGER NOT NULL,
              seq INTEGER NOT NULL,
              is_user INTEGER NOT NULL,
              text TEXT NOT NULL,
              citations TEXT,
              created_at TEXT NOT NULL
            )
          ''');
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
        },
      ),
    );

    final now = DateTime.now().toIso8601String();
    await db.insert('conversations', {
      'title': 'What is grace?',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('conversation_messages', {
      'conversation_id': 1,
      'seq': 0,
      'is_user': 0,
      'text': 'Augustine calls it prevenient.',
      'created_at': now,
    });
    await db.insert('notes', {
      'body': 'Written before the upgrade.',
      'quote': 'We believe and confess…',
      'created_at': now,
      'updated_at': now,
    });
    await db.close();
  }

  test('a version 1 database keeps its contents and gains the new column',
      () async {
    final path = p.join(dir.path, UserDatabase.fileName);
    await createVersion1(path);

    final upgraded = await UserDatabase.openAt(path);
    UserDatabase.adoptForTesting(upgraded);

    // Nothing the reader wrote is lost.
    final notes = await upgraded.query('notes');
    expect(notes, hasLength(1));
    expect(notes.single['body'], 'Written before the upgrade.');

    final messages = await ChatHistoryService().messages(1);
    expect(messages, hasLength(1));
    expect(messages.single.text, 'Augustine calls it prevenient.');

    // An answer from before the column existed reads as not-generated, so an
    // old thread simply shows no caveat rather than one on the wrong message.
    expect(messages.single.generated, isFalse);

    // And the column is now writable.
    final id = await ChatHistoryService()
        .addMessage(conversationId: 1, isUser: false, text: 'x', generated: true);
    expect(id, greaterThan(0));
    expect((await ChatHistoryService().messages(1)).last.generated, isTrue);

    await upgraded.close();
  });

  test('a fresh database is created at the current version', () async {
    final path = p.join(dir.path, UserDatabase.fileName);
    final db = await UserDatabase.openAt(path);
    expect(await db.getVersion(), UserDatabase.schemaVersion);

    final columns = await db.rawQuery(
        'PRAGMA table_info(conversation_messages)');
    expect(columns.map((c) => c['name']), contains('generated'));
    await db.close();
  });
}

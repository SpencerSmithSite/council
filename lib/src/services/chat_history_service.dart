import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'user_database.dart';

/// A passage a conversation is anchored to.
///
/// Set when the reader selected text and asked about it, so that reopening the
/// conversation weeks later still shows what was being discussed — a thread of
/// "what does this mean?" with the "this" missing is not resumable.
class PinnedPassage {
  final int contentUnitId;
  final String quote;
  final String reference;
  final String? sourceTitle;

  const PinnedPassage({
    required this.contentUnitId,
    required this.quote,
    required this.reference,
    this.sourceTitle,
  });

  /// How the passage is described to the model.
  String get promptLabel => [
        if (sourceTitle != null && sourceTitle!.isNotEmpty) sourceTitle!,
        if (reference.isNotEmpty) reference,
      ].join(' — ');
}

class Conversation {
  final int id;
  final String title;
  final PinnedPassage? passage;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Filled in by [ChatHistoryService.conversations], which is the only place
  /// that needs them — the list screen shows both and would otherwise run a
  /// query per row.
  final int messageCount;
  final String? preview;

  const Conversation({
    required this.id,
    required this.title,
    this.passage,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.preview,
  });

  static Conversation fromRow(Map<String, Object?> row) {
    final unitId = row['passage_unit_id'] as int?;
    return Conversation(
      id: row['id'] as int,
      title: row['title'] as String,
      passage: unitId == null
          ? null
          : PinnedPassage(
              contentUnitId: unitId,
              quote: row['passage_quote'] as String? ?? '',
              reference: row['passage_reference'] as String? ?? '',
              sourceTitle: row['passage_source'] as String?,
            ),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      messageCount: (row['message_count'] as int?) ?? 0,
      preview: row['preview'] as String?,
    );
  }
}

/// One turn, stored with the citations it was answered from.
///
/// The citations are kept as JSON rather than as rows of their own. They are
/// only ever read back with their message, never queried across, and a passage
/// can be removed from the corpus by a pack change — at which point a foreign
/// key would either block the delete or take the answer's provenance with it.
class StoredMessage {
  final int id;
  final bool isUser;
  final String text;
  final List<Map<String, dynamic>> citations;

  /// True when a language model wrote this, rather than the app itself.
  ///
  /// Drives the once-per-thread reliability caveat: a retrieval-only result or
  /// an error notice is the app speaking and needs no such warning, and
  /// attaching one there would train the reader to ignore it.
  final bool generated;

  final DateTime createdAt;

  const StoredMessage({
    required this.id,
    required this.isUser,
    required this.text,
    this.citations = const [],
    this.generated = false,
    required this.createdAt,
  });

  static StoredMessage fromRow(Map<String, Object?> row) {
    final raw = row['citations'] as String?;
    var citations = const <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        citations = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>()
            .toList(growable: false);
      } catch (_) {
        // A malformed blob costs the citations on one message; it must not
        // cost the reader their conversation.
        citations = const [];
      }
    }
    return StoredMessage(
      id: row['id'] as int,
      isUser: (row['is_user'] as int) == 1,
      text: row['text'] as String,
      citations: citations,
      generated: (row['generated'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

/// Conversations with the model, kept so they can be returned to.
class ChatHistoryService {
  Future<Database> get _db async => UserDatabase.open();

  /// Conversations, most recently active first, with a one-line preview.
  ///
  /// Empty conversations are excluded. One is created the moment a reader taps
  /// "ask about this passage", and if they change their mind and go back, the
  /// history should not fill up with threads that were never had.
  Future<List<Conversation>> conversations({int limit = 200}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT c.*,
             (SELECT COUNT(*) FROM conversation_messages m
               WHERE m.conversation_id = c.id) AS message_count,
             (SELECT m.text FROM conversation_messages m
               WHERE m.conversation_id = c.id
               ORDER BY m.seq DESC LIMIT 1) AS preview
      FROM conversations c
      WHERE message_count > 0
      ORDER BY c.updated_at DESC, c.id DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(Conversation.fromRow).toList();
  }

  Future<Conversation?> conversation(int id) async {
    final db = await _db;
    final rows = await db.query('conversations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Conversation.fromRow(rows.first);
  }

  Future<Conversation> createConversation({
    String title = 'New conversation',
    PinnedPassage? passage,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final id = await db.insert('conversations', {
      'title': title,
      'passage_unit_id': passage?.contentUnitId,
      'passage_quote': passage?.quote,
      'passage_reference': passage?.reference,
      'passage_source': passage?.sourceTitle,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    return Conversation(
      id: id,
      title: title,
      passage: passage,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<List<StoredMessage>> messages(int conversationId) async {
    final db = await _db;
    final rows = await db.query(
      'conversation_messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'seq, id',
    );
    return rows.map(StoredMessage.fromRow).toList();
  }

  /// Append a turn, and mark the conversation as active.
  ///
  /// Returns the row id so a streaming answer can be written once and then
  /// updated in place as it arrives, rather than inserted per chunk.
  Future<int> addMessage({
    required int conversationId,
    required bool isUser,
    required String text,
    List<Map<String, dynamic>> citations = const [],
    bool generated = false,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final seq = (Sqflite.firstIntValue(await db.rawQuery(
              'SELECT MAX(seq) FROM conversation_messages '
              'WHERE conversation_id = ?',
              [conversationId],
            )) ??
            -1) +
        1;

    final id = await db.insert('conversation_messages', {
      'conversation_id': conversationId,
      'seq': seq,
      'is_user': isUser ? 1 : 0,
      'text': text,
      'citations': citations.isEmpty ? null : jsonEncode(citations),
      'generated': generated ? 1 : 0,
      'created_at': now.toIso8601String(),
    });
    await _touch(conversationId, now);
    return id;
  }

  Future<void> updateMessage(
    int messageId, {
    required String text,
    List<Map<String, dynamic>> citations = const [],
    int? conversationId,
  }) async {
    final db = await _db;
    await db.update(
      'conversation_messages',
      {
        'text': text,
        'citations': citations.isEmpty ? null : jsonEncode(citations),
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (conversationId != null) await _touch(conversationId, DateTime.now());
  }

  /// Name a conversation after its opening question.
  ///
  /// Only takes effect while the conversation is still called what it was
  /// created as, so a title the reader is shown does not change under them as
  /// the thread goes on.
  Future<void> retitleIfUnnamed(int conversationId, String title) async {
    final db = await _db;
    final clean = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return;
    await db.update(
      'conversations',
      {'title': clean.length > 80 ? '${clean.substring(0, 80)}…' : clean},
      where: 'id = ? AND title = ?',
      whereArgs: [conversationId, 'New conversation'],
    );
  }

  Future<void> deleteConversation(int id) async {
    final db = await _db;
    await db.delete('conversation_messages',
        where: 'conversation_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// Discard a conversation that was opened and never used.
  Future<void> deleteIfEmpty(int id) async {
    final db = await _db;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM conversation_messages WHERE conversation_id = ?',
      [id],
    ));
    if (count == 0) {
      await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> _touch(int conversationId, DateTime when) async {
    final db = await _db;
    await db.update(
      'conversations',
      {'updated_at': when.toIso8601String()},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }
}

import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../utils/id.dart';
import 'app_database.dart';

/// CRUD for the local chat history.
class ChatRepository {
  ChatRepository(this._database);

  static const String _lastConversationKey = 'last_conversation_id';

  final AppDatabase _database;

  Database get _db => _database.database;

  Future<List<Conversation>> listConversations() async {
    final rows = await _db.rawQuery('''
      SELECT
        c.id,
        c.title,
        c.created_at,
        c.updated_at,
        c.draft,
        (SELECT COUNT(*) FROM messages m
          WHERE m.conversation_id = c.id) AS message_count
      FROM conversations c
      ORDER BY c.updated_at DESC, c.created_at DESC
    ''');
    return rows.map(Conversation.fromRow).toList(growable: false);
  }

  Future<Conversation?> getConversation(String id) async {
    final rows = await _db.rawQuery(
      '''
      SELECT
        c.id,
        c.title,
        c.created_at,
        c.updated_at,
        c.draft,
        (SELECT COUNT(*) FROM messages m
          WHERE m.conversation_id = c.id) AS message_count
      FROM conversations c
      WHERE c.id = ?
      LIMIT 1
    ''',
      [id],
    );
    if (rows.isEmpty) return null;
    return Conversation.fromRow(rows.first);
  }

  Future<Conversation> createConversation({String title = 'New chat'}) async {
    final now = DateTime.now();
    final conversation = Conversation(
      id: newId(),
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert('conversations', conversation.toRow());
    return conversation;
  }

  Future<void> renameConversation(String id, String title) async {
    await _db.update(
      'conversations',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveDraft(String id, String draft) async {
    await _db.update(
      'conversations',
      {'draft': draft},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchConversation(String id) async {
    await _db.update(
      'conversations',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'seq ASC, created_at ASC',
    );
    return rows.map(ChatMessage.fromRow).toList(growable: false);
  }

  /// Inserts a message or updates its content if it already exists.
  ///
  /// Streaming replies call this periodically so a partial answer is kept even
  /// if Android kills the app while the model is still generating.
  Future<void> saveMessage(
    String conversationId,
    ChatMessage message, {
    String? title,
    bool touch = true,
  }) async {
    final values = message.toRow(conversationId);

    await _db.transaction((txn) async {
      final updated = await txn.update(
        'messages',
        values,
        where: 'id = ?',
        whereArgs: [message.id],
      );
      if (updated == 0) {
        await txn.insert('messages', values);
      }

      if (touch || title != null) {
        final conversationValues = <String, Object?>{
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        if (title != null) conversationValues['title'] = title;
        await txn.update(
          'conversations',
          conversationValues,
          where: 'id = ?',
          whereArgs: [conversationId],
        );
      }
    });
  }

  Future<void> deleteConversation(String id) async {
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAllConversations() async {
    await _db.transaction((txn) async {
      await txn.delete('conversations');
      await txn.delete(
        'settings',
        where: 'key = ?',
        whereArgs: [_lastConversationKey],
      );
    });
  }

  Future<int> countConversations() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM conversations',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<String?> getLastConversationId() =>
      _database.getSetting(_lastConversationKey);

  Future<void> setLastConversationId(String id) =>
      _database.setSetting(_lastConversationKey, id);

  Future<void> clearLastConversationId() =>
      _database.removeSetting(_lastConversationKey);
}

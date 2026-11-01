import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_chat/models/chat_message.dart';
import 'package:offline_ai_chat/services/app_database.dart';
import 'package:offline_ai_chat/services/chat_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late AppDatabase database;
  late ChatRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_ai_test_');
    database = await AppDatabase.open(path: p.join(tempDir.path, 'test.db'));
    repository = ChatRepository(database);
  });

  tearDown(() async {
    await database.database.close();
    await tempDir.delete(recursive: true);
  });

  test('saves and restores conversations, messages, drafts, and settings',
      () async {
    final conversation = await repository.createConversation();

    final user = ChatMessage(
      id: 'u1',
      role: ChatRole.user,
      content: 'hello',
      createdAt: DateTime(2026, 1, 1),
      sequence: 0,
    );
    final assistant = ChatMessage(
      id: 'a1',
      role: ChatRole.assistant,
      content: 'hi',
      createdAt: DateTime(2026, 1, 1),
      sequence: 1,
    );

    await repository.saveMessage(conversation.id, user, title: 'hello');
    await repository.saveMessage(conversation.id, assistant);
    await repository.saveDraft(conversation.id, 'draft text');
    await repository.setLastConversationId(conversation.id);
    await database.setSetting('generation_temperature', '0.4');

    final conversations = await repository.listConversations();
    expect(conversations, hasLength(1));
    expect(conversations.first.title, 'hello');
    expect(conversations.first.messageCount, 2);
    expect(conversations.first.draft, 'draft text');

    final messages = await repository.loadMessages(conversation.id);
    expect(messages.map((message) => message.content), ['hello', 'hi']);
    expect(messages.map((message) => message.role), [
      ChatRole.user,
      ChatRole.assistant,
    ]);
    expect(messages.map((message) => message.sequence), [0, 1]);

    expect(await repository.getLastConversationId(), conversation.id);
    expect(await database.getSetting('generation_temperature'), '0.4');
  });

  test('updates a streamed message instead of duplicating it', () async {
    final conversation = await repository.createConversation();
    var message = ChatMessage(
      id: 'a1',
      role: ChatRole.assistant,
      content: 'part',
      createdAt: DateTime(2026, 1, 1),
    );
    await repository.saveMessage(conversation.id, message);

    message = message.copyWith(content: 'partial answer');
    await repository.saveMessage(conversation.id, message, touch: false);

    final messages = await repository.loadMessages(conversation.id);
    expect(messages, hasLength(1));
    expect(messages.first.content, 'partial answer');
  });

  test('deleting a conversation cascades to its messages', () async {
    final conversation = await repository.createConversation();
    await repository.saveMessage(
      conversation.id,
      ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        content: 'x',
        createdAt: DateTime.now(),
      ),
    );

    expect(await repository.countConversations(), 1);
    await repository.deleteConversation(conversation.id);
    expect(await repository.countConversations(), 0);
    expect(await repository.loadMessages(conversation.id), isEmpty);
  });
}

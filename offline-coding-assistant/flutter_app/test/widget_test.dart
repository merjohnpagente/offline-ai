import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_chat/models/chat_message.dart';

void main() {
  test('ChatMessage serializes to the API shape', () {
    final message = ChatMessage(
      id: '1',
      role: ChatRole.user,
      content: 'hello',
      createdAt: DateTime(2026, 1, 1),
    );

    expect(message.toApiJson(), {'role': 'user', 'content': 'hello'});
  });
}

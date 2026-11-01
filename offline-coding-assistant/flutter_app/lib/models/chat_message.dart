enum ChatRole { system, user, assistant }

class ChatMessage {
  final String id;
  final ChatRole role;
  final String content;
  final bool isStreaming;
  final DateTime createdAt;

  /// Position inside the conversation. Stored in SQLite so restored chats keep
  /// their original order even when timestamps collide.
  final int sequence;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.isStreaming = false,
    required this.createdAt,
    this.sequence = 0,
  });

  factory ChatMessage.fromRow(Map<String, Object?> row) {
    final roleName = row['role'] as String? ?? 'assistant';
    return ChatMessage(
      id: row['id'] as String,
      role: ChatRole.values.firstWhere(
        (role) => role.name == roleName,
        orElse: () => ChatRole.assistant,
      ),
      content: row['content'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int? ?? 0,
      ),
      sequence: row['seq'] as int? ?? 0,
    );
  }

  Map<String, Object?> toRow(String conversationId) {
    return {
      'id': id,
      'conversation_id': conversationId,
      'role': role.name,
      'content': content,
      'created_at': createdAt.millisecondsSinceEpoch,
      'seq': sequence,
    };
  }

  ChatMessage copyWith({String? content, bool? isStreaming, int? sequence}) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      createdAt: createdAt,
      sequence: sequence ?? this.sequence,
    );
  }

  Map<String, dynamic> toApiJson() => {'role': role.name, 'content': content};
}

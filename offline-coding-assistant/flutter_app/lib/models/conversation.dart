/// A saved chat thread.
///
/// Conversations, their messages, drafts, and app settings all live in a local
/// SQLite database so nothing is lost when the app is closed or restarted.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.draft = '',
    this.messageCount = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Text typed into the composer but not sent yet.
  final String draft;

  /// Number of messages currently stored for this conversation.
  final int messageCount;

  factory Conversation.fromRow(Map<String, Object?> row) {
    return Conversation(
      id: row['id'] as String,
      title: row['title'] as String? ?? 'New chat',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int? ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
      draft: row['draft'] as String? ?? '',
      messageCount: row['message_count'] as int? ?? 0,
    );
  }

  Map<String, Object?> toRow() {
    return {
      'id': id,
      'title': title,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      'draft': draft,
    };
  }

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    String? draft,
    int? messageCount,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      draft: draft ?? this.draft,
      messageCount: messageCount ?? this.messageCount,
    );
  }
}

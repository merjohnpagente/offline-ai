import 'package:flutter/material.dart';

import '../models/conversation.dart';

class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({
    required this.conversations,
    required this.currentId,
    required this.onNewChat,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onClearAll,
    super.key,
  });

  final List<Conversation> conversations;
  final String? currentId;
  final VoidCallback onNewChat;
  final ValueChanged<Conversation> onSelect;
  final ValueChanged<Conversation> onRename;
  final ValueChanged<Conversation> onDelete;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.forum_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Chats', style: theme.textTheme.titleLarge),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'New chat',
                    onPressed: onNewChat,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.storage_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Saved on this device in SQLite',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: conversations.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No saved chats yet.\nStart a new conversation.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final selected = conversation.id == currentId;
                        final count = conversation.messageCount;
                        final countLabel =
                            '$count ${count == 1 ? 'message' : 'messages'}';

                        return ListTile(
                          selected: selected,
                          selectedTileColor: theme
                              .colorScheme
                              .secondaryContainer
                              .withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(
                            selected
                                ? Icons.chat_bubble
                                : Icons.chat_bubble_outline,
                          ),
                          title: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '$countLabel · ${_relativeTime(conversation.updatedAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Chat options',
                            onSelected: (value) {
                              if (value == 'rename') onRename(conversation);
                              if (value == 'delete') onDelete(conversation);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                          onTap: () => onSelect(conversation),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Clear all chats'),
              onTap: onClearAll,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Uninstalling the app removes local chats.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _relativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.isNegative || difference.inMinutes < 1) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes}m ago';
  if (difference.inDays < 1) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';

  final local = time.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

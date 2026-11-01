import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/chat_repository.dart';
import '../services/local_ai_service.dart';
import '../services/settings_service.dart';
import '../utils/id.dart';
import '../widgets/conversation_drawer.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({required this.ai, super.key});

  final LocalAiService ai;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final List<ChatMessage> _messages = [];

  late final ChatRepository _repo;
  StreamSubscription<String>? _subscription;
  Timer? _draftTimer;
  Timer? _snapshotTimer;
  Conversation? _conversation;
  List<Conversation> _conversations = const [];
  int _nextSequence = 0;
  int _generation = 0;
  bool _sending = false;
  bool _loadingHistory = true;
  bool _disposed = false;
  bool _suppressDraftSave = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = context.read<ChatRepository>();
    _input.addListener(_onDraftChanged);
    unawaited(_restoreConversation());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    _snapshotTimer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;

    // Best-effort final save. The lifecycle callback normally gets here first.
    final conversation = _conversation;
    if (conversation != null) {
      unawaited(_repo.saveDraft(conversation.id, _input.text));
    }
    _snapshotStreaming();

    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _draftTimer?.cancel();
      final conversation = _conversation;
      if (conversation != null) {
        unawaited(_repo.saveDraft(conversation.id, _input.text));
      }
      _snapshotStreaming();
    }
  }

  Future<void> _restoreConversation() async {
    try {
      final lastId = await _repo.getLastConversationId();
      final conversations = await _repo.listConversations();

      Conversation? target;
      if (lastId != null) {
        for (final conversation in conversations) {
          if (conversation.id == lastId) {
            target = conversation;
            break;
          }
        }
      }
      target ??= conversations.isNotEmpty ? conversations.first : null;

      final isNew = target == null;
      final conversation = target ?? await _repo.createConversation();
      final messages = await _repo.loadMessages(conversation.id);
      final conversationsForDrawer = isNew
          ? <Conversation>[conversation, ...conversations]
          : conversations;

      if (_disposed) return;
      setState(() {
        _conversation = conversation;
        _messages
          ..clear()
          ..addAll(messages);
        _nextSequence = messages.isEmpty ? 0 : messages.last.sequence + 1;
        _conversations = conversationsForDrawer;
        _loadingHistory = false;
      });
      _setInputText(conversation.draft);
      await _repo.setLastConversationId(conversation.id);
      _scrollToBottom(jump: true);
    } catch (error) {
      if (_disposed) return;
      setState(() {
        _loadingHistory = false;
        _error = 'Could not open local chat history: $error';
      });
    }
  }

  Future<void> _openConversation(
    Conversation conversation, {
    bool closeDrawer = true,
  }) async {
    if (conversation.id == _conversation?.id && !_loadingHistory) {
      if (closeDrawer) _scaffoldKey.currentState?.closeDrawer();
      return;
    }

    await _cancelStream();
    await _flushDraft();

    final fresh = await _repo.getConversation(conversation.id) ?? conversation;
    final messages = await _repo.loadMessages(fresh.id);
    if (_disposed) return;

    setState(() {
      _conversation = fresh;
      _messages
        ..clear()
        ..addAll(messages);
      _nextSequence = messages.isEmpty ? 0 : messages.last.sequence + 1;
      _error = null;
      _loadingHistory = false;
    });
    _setInputText(fresh.draft);
    await _repo.setLastConversationId(fresh.id);
    if (closeDrawer) _scaffoldKey.currentState?.closeDrawer();
    _scrollToBottom(jump: true);
  }

  Future<void> _startNewSession() async {
    await _cancelStream();
    await _flushDraft();

    if (_messages.isEmpty) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }

    final conversation = await _repo.createConversation();
    if (_disposed) return;

    setState(() {
      _conversation = conversation;
      _messages.clear();
      _nextSequence = 0;
      _sending = false;
      _error = null;
      _loadingHistory = false;
    });
    _setInputText('');
    await _repo.setLastConversationId(conversation.id);
    await _refreshConversations();
    _scaffoldKey.currentState?.closeDrawer();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final conversation = _conversation;
    if (text.isEmpty || _sending || conversation == null) return;

    final settings = context.read<SettingsService>();
    final isFirstMessage = _messages.isEmpty;
    final title = isFirstMessage ? _titleFrom(text) : null;

    final user = ChatMessage(
      id: newId(),
      role: ChatRole.user,
      content: text,
      createdAt: DateTime.now(),
      sequence: _nextSequence++,
    );
    final assistant = ChatMessage(
      id: newId(),
      role: ChatRole.assistant,
      content: '',
      isStreaming: true,
      createdAt: DateTime.now(),
      sequence: _nextSequence++,
    );

    _draftTimer?.cancel();
    setState(() {
      _messages
        ..add(user)
        ..add(assistant);
      _sending = true;
      _error = null;
      if (title != null) {
        _conversation = conversation.copyWith(
          title: title,
          updatedAt: DateTime.now(),
        );
      }
    });
    _setInputText('');
    _scrollToBottom();
    unawaited(_repo.saveDraft(conversation.id, ''));

    final generation = ++_generation;
    await _repo.saveMessage(conversation.id, user, title: title);
    if (_disposed ||
        generation != _generation ||
        _conversation?.id != conversation.id) {
      return;
    }

    final history = _messages
        .where((message) => !message.isStreaming)
        .where((message) => message.content.trim().isNotEmpty)
        .toList(growable: false);

    _subscription = widget.ai
        .streamReply(
          history: history,
          temperature: settings.temperature,
          maxTokens: settings.maxTokens,
        )
        .listen(
          (chunk) {
            if (_disposed || generation != _generation) return;
            final index = _messages.indexWhere(
              (message) => message.id == assistant.id,
            );
            if (index == -1) return;
            setState(() {
              _messages[index] = _messages[index].copyWith(
                content: _messages[index].content + chunk,
                isStreaming: true,
              );
            });
            _scheduleSnapshot(assistant.id, generation);
            _scrollToBottom();
          },
          onError: (Object error) {
            if (_disposed || generation != _generation) return;
            unawaited(_finishStream(assistant.id, error: error));
          },
          onDone: () {
            if (_disposed || generation != _generation) return;
            unawaited(_finishStream(assistant.id));
          },
          cancelOnError: true,
        );
  }

  Future<void> _finishStream(String assistantId, {Object? error}) async {
    _snapshotTimer?.cancel();
    _subscription = null;

    final conversation = _conversation;
    final index = _messages.indexWhere((message) => message.id == assistantId);
    ChatMessage? finalMessage;

    if (mounted) {
      setState(() {
        if (index != -1) {
          finalMessage = _messages[index].copyWith(isStreaming: false);
          if (finalMessage!.content.trim().isEmpty) {
            _messages.removeAt(index);
          } else {
            _messages[index] = finalMessage!;
          }
        }
        _sending = false;
        if (error != null) _error = error.toString();
      });
    }

    final messageToSave = finalMessage;
    if (conversation != null &&
        messageToSave != null &&
        messageToSave.content.trim().isNotEmpty) {
      await _repo.saveMessage(conversation.id, messageToSave, touch: true);
    }
    await _refreshConversations();
    _scrollToBottom();
  }

  void _stop() {
    unawaited(_cancelStream());
  }

  Future<void> _cancelStream() async {
    _generation++;
    _snapshotTimer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _finalizeStreaming();
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _finalizeStreaming({bool touch = true}) async {
    final conversation = _conversation;
    if (conversation == null) return;

    final index = _messages.lastIndexWhere((message) => message.isStreaming);
    if (index == -1) return;

    final message = _messages[index].copyWith(isStreaming: false);
    if (mounted) {
      setState(() {
        if (message.content.trim().isEmpty) {
          _messages.removeAt(index);
        } else {
          _messages[index] = message;
        }
      });
    }

    if (message.content.trim().isEmpty) return;
    await _repo.saveMessage(conversation.id, message, touch: touch);
  }

  /// Saves the partial reply without changing the streaming UI state.
  void _snapshotStreaming() {
    final conversation = _conversation;
    if (conversation == null) return;
    final index = _messages.lastIndexWhere((message) => message.isStreaming);
    if (index == -1) return;
    final message = _messages[index];
    if (message.content.trim().isEmpty) return;
    unawaited(_repo.saveMessage(conversation.id, message, touch: false));
  }

  void _scheduleSnapshot(String assistantId, int generation) {
    if (_snapshotTimer?.isActive ?? false) return;
    _snapshotTimer = Timer(const Duration(milliseconds: 900), () {
      if (_disposed || generation != _generation) return;
      final conversation = _conversation;
      if (conversation == null) return;
      final index = _messages.indexWhere(
        (message) => message.id == assistantId,
      );
      if (index == -1) return;
      final message = _messages[index];
      if (message.content.trim().isEmpty) return;
      unawaited(_repo.saveMessage(conversation.id, message, touch: false));
    });
  }

  void _onDraftChanged() {
    if (_suppressDraftSave || _loadingHistory) return;
    final conversation = _conversation;
    if (conversation == null) return;
    final text = _input.text;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_repo.saveDraft(conversation.id, text));
    });
  }

  void _setInputText(String text) {
    _suppressDraftSave = true;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressDraftSave = false;
  }

  Future<void> _flushDraft() async {
    _draftTimer?.cancel();
    final conversation = _conversation;
    if (conversation == null) return;
    await _repo.saveDraft(conversation.id, _input.text);
  }

  Future<void> _refreshConversations() async {
    final conversations = await _repo.listConversations();
    if (_disposed) return;
    setState(() => _conversations = conversations);
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          '“${conversation.title}” and its messages will be removed from '
          'this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || _disposed) return;

    final deletingCurrent = conversation.id == _conversation?.id;
    if (deletingCurrent) {
      await _cancelStream();
      await _flushDraft();
    }
    await _repo.deleteConversation(conversation.id);
    await _refreshConversations();
    if (_disposed) return;

    if (deletingCurrent) {
      final next = _conversations.isNotEmpty
          ? _conversations.first
          : await _repo.createConversation();
      await _openConversation(next, closeDrawer: false);
    }
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty || _disposed) return;

    await _repo.renameConversation(conversation.id, trimmed);
    if (_disposed) return;
    if (_conversation?.id == conversation.id) {
      setState(() => _conversation = _conversation!.copyWith(title: trimmed));
    }
    await _refreshConversations();
  }

  Future<void> _clearAllChats() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all chats?'),
        content: const Text(
          'Every saved conversation, message, and draft will be deleted from '
          'this device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true || _disposed) return;

    await _cancelStream();
    await _flushDraft();
    await _repo.deleteAllConversations();

    final conversation = await _repo.createConversation();
    if (_disposed) return;
    setState(() {
      _conversation = conversation;
      _messages.clear();
      _nextSequence = 0;
      _sending = false;
      _error = null;
      _loadingHistory = false;
    });
    _setInputText('');
    await _repo.setLastConversationId(conversation.id);
    await _refreshConversations();
    _scaffoldKey.currentState?.closeDrawer();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(modelName: widget.ai.modelName),
      ),
    );
    if (mounted) setState(() {});
  }

  String _titleFrom(String text) {
    final singleLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= 48) return singleLine;
    return '${singleLine.substring(0, 47)}…';
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      key: _scaffoldKey,
      drawer: ConversationDrawer(
        conversations: _conversations,
        currentId: _conversation?.id,
        onNewChat: _startNewSession,
        onSelect: (conversation) => unawaited(_openConversation(conversation)),
        onRename: (conversation) =>
            unawaited(_renameConversation(conversation)),
        onDelete: (conversation) =>
            unawaited(_deleteConversation(conversation)),
        onClearAll: () => unawaited(_clearAllChats()),
      ),
      onDrawerChanged: (open) {
        if (open) unawaited(_refreshConversations());
      },
      appBar: AppBar(
        title: const Text('Offline AI'),
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: _startNewSession,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(
                    Icons.offline_bolt,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'On-device · ${widget.ai.modelName} · saved in SQLite',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null)
              _ErrorBanner(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            Expanded(
              child: _loadingHistory
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                  ? _EmptyChat(
                      onSuggestion: (text) {
                        _setInputText(text);
                        _inputFocus.requestFocus();
                      },
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        return _MessageBubble(
                          key: ValueKey(message.id),
                          message: message,
                        );
                      },
                    ),
            ),
            _Composer(
              controller: _input,
              focusNode: _inputFocus,
              sending: _sending,
              onSend: _send,
              onStop: _stop,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const List<String> _suggestions = [
    'Explain this error and how to fix it',
    'Write a Flutter widget for a settings page',
    'Review this function for bugs',
    'Convert this Python code to Dart',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 48).clamp(0, double.infinity),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.terminal,
                      size: 38,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'What are we building?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ask about code, paste an error, or pick a starter below. '
                    'Your chats stay on this phone.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final suggestion in _suggestions)
                        ActionChip(
                          label: Text(suggestion),
                          onPressed: () => onSuggestion(suggestion),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isUser = message.role == ChatRole.user;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.84;

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16),
              ),
            ),
            child: isUser
                ? SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      height: 1.4,
                    ),
                  )
                : (message.content.isEmpty && message.isStreaming)
                ? const _TypingIndicator()
                : MarkdownBody(
                    data: message.content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                      h1: theme.textTheme.titleLarge,
                      h2: theme.textTheme.titleMedium,
                      h3: theme.textTheme.titleSmall,
                      code: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        backgroundColor: theme.colorScheme.surface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.6),
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 3,
                          ),
                        ),
                      ),
                      listBullet: theme.textTheme.bodyMedium,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < 3; index++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _dot(index, color),
                  ),
              ],
            );
          },
        ),
        const SizedBox(width: 8),
        Text('Thinking…', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _dot(int index, Color color) {
    final phase = (_controller.value + index * 0.18) % 1.0;
    final wave = (1 - (2 * phase - 1).abs()).clamp(0.0, 1.0).toDouble();
    return Transform.translate(
      offset: Offset(0, -2.5 * wave),
      child: Opacity(
        opacity: 0.35 + 0.65 * wave,
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: colors.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: 'Ask about your code…',
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: sending ? 'Stop' : 'Send',
            onPressed: sending ? onStop : onSend,
            icon: Icon(sending ? Icons.stop : Icons.send),
          ),
        ],
      ),
    );
  }
}

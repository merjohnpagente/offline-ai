import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../models/attached_file.dart';
import '../models/chat_message.dart';

/// Owns the on-device llama.cpp engine and streams completions.
class LocalAiService {
  LlamaEngine? _engine;
  String? _modelPath;

  bool get isReady => _engine?.isReady ?? false;
  String? get modelPath => _modelPath;
  String get modelName =>
      _modelPath == null ? 'No model' : p.basename(_modelPath!);

  static const String systemPrompt = '''
You are a private, offline coding assistant running entirely on the user's phone.
Be precise, practical, and honest. Prefer small, reviewable changes.
When you show code, include the file path and a complete runnable snippet.
Never invent APIs, commands, or test results. If information is missing, ask one
focused question. You have no internet access and cannot browse or install
packages. Keep answers concise unless the user asks for a detailed explanation.
''';

  Future<void> load(
    String path, {
    int contextSize = 4096,
    int gpuLayers = 0,
    int threads = 4,
  }) async {
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(path)),
      params: ModelParams(
        contextSize: contextSize,
        gpuLayers: gpuLayers,
        numberOfThreads: threads,
      ),
    );
    _engine = engine;
    _modelPath = path;
  }

  Stream<String> streamReply({
    required List<ChatMessage> history,
    double temperature = 0.2,
    int maxTokens = 512,
    AttachedFile? attachment,
  }) async* {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('The local model is not loaded yet.');
    }

    final system = StringBuffer(systemPrompt);
    if (attachment != null && attachment.content.trim().isNotEmpty) {
      system
        ..write(
          '\n\nThe user attached the file "${attachment.name}". Treat its '
          'contents as the primary context for their questions and quote only '
          'the parts that matter.',
        )
        ..write(
          attachment.truncated
              ? ' The file is ${attachment.sizeLabel}; only its beginning was '
                    'included to fit the context window.'
              : '',
        )
        ..write('\n\n<attached_file name="${attachment.name}">\n')
        ..write(attachment.content)
        ..write('\n</attached_file>');
    }

    final messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text: system.toString(),
      ),
      ...history
          .where((message) => message.role != ChatRole.system)
          .where((message) => message.content.trim().isNotEmpty)
          .map(
            (message) => LlamaChatMessage.fromText(
              role: _role(message.role),
              text: message.content,
            ),
          ),
    ];

    final trimmed = _trim(
      messages,
      maxHistoryChars: attachment == null ? 12000 : 2000,
    );
    final stream = engine.create(
      trimmed,
      params: GenerationParams(
        maxTokens: maxTokens,
        temp: temperature,
        topK: 40,
        topP: 0.9,
        penalty: 1.05,
        stopSequences: const ['<|im_end|>'],
      ),
    );

    await for (final chunk in stream) {
      final text = chunk.text;
      if (text.isNotEmpty) yield text;
    }
  }

  List<LlamaChatMessage> _trim(
    List<LlamaChatMessage> messages, {
    int maxHistoryChars = 12000,
  }) {
    if (messages.isEmpty) return messages;
    final system = messages.first;
    final rest = messages.skip(1).toList();

    // Keep the prompt inside the 4K context window. This is intentionally
    // conservative because code blocks tokenize poorly. An attached file takes
    // most of the budget, so the history gets much tighter.
    while (rest.length > 8) {
      rest.removeAt(0);
    }
    while (rest.length > 1 &&
        rest.fold<int>(0, (sum, message) => sum + message.content.length) >
            maxHistoryChars) {
      rest.removeAt(0);
    }

    return [system, ...rest];
  }

  LlamaChatRole _role(ChatRole role) {
    switch (role) {
      case ChatRole.system:
        return LlamaChatRole.system;
      case ChatRole.user:
        return LlamaChatRole.user;
      case ChatRole.assistant:
        return LlamaChatRole.assistant;
    }
  }

  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    _modelPath = null;
    await engine?.dispose();
  }
}

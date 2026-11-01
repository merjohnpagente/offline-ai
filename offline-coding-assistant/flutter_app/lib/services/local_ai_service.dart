import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

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
  }) async* {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw StateError('The local model is not loaded yet.');
    }

    final messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text: systemPrompt,
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

    final trimmed = _trim(messages);
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

  List<LlamaChatMessage> _trim(List<LlamaChatMessage> messages) {
    if (messages.isEmpty) return messages;
    final system = messages.first;
    final rest = messages.skip(1).toList();

    // Keep the prompt inside the 4K context window. This is intentionally
    // conservative because code blocks tokenize poorly.
    while (rest.length > 8) {
      rest.removeAt(0);
    }
    while (rest.length > 1 &&
        rest.fold<int>(0, (sum, message) => sum + message.content.length) >
            12000) {
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

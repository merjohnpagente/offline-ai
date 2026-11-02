import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../models/attached_file.dart';

/// Lets the user pick a text or code file and reads a context-sized slice.
class FileAttachmentService {
  /// Hard cap for the bytes copied into the prompt.
  ///
  /// The app runs the model with a 4096-token context, so a larger slice would
  /// crowd out the conversation and the reply.
  static const int maxBytes = 6 * 1024;

  Future<AttachedFile?> pick() async {
    final file = await openFile();
    if (file == null) return null;

    final length = await file.length();
    if (length == 0) {
      throw const FormatException('That file is empty.');
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, maxBytes)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (_looksBinary(bytes)) {
      throw const FormatException(
        'That looks like a binary file. Pick a text or code file.',
      );
    }

    return AttachedFile(
      name: file.name.isEmpty ? 'attached file' : file.name,
      content: utf8.decode(bytes, allowMalformed: true),
      byteCount: length,
      truncated: length > bytes.length,
    );
  }

  bool _looksBinary(Uint8List bytes) {
    final sample = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
    var suspicious = 0;
    for (final byte in sample) {
      if (byte == 0) return true;
      final printable = byte == 9 || byte == 10 || byte == 13 || byte >= 32;
      if (!printable) suspicious++;
    }
    return suspicious > sample.length ~/ 10;
  }
}

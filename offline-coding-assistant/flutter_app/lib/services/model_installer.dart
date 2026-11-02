import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copies the bundled GGUF out of the APK into app-private storage.
///
/// Flutter assets are packed inside the APK and llama.cpp needs a real file
/// path. The Android/iOS side streams the copy, so a 1 GB model is not loaded
/// into Dart memory all at once.
class ModelInstaller {
  static const MethodChannel _channel =
      MethodChannel('offline_ai/model_installer');

  static const String assetPath = 'assets/models/model.gguf';
  static const String fileName = 'model.gguf';

  /// A real Q4_K_M 0.5B model is ~470 MB. This rejects an empty placeholder.
  static const int minimumBytes = 100 * 1024 * 1024;

  Future<String> ensureModel({void Function(String status)? onStatus}) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'models'));
    await dir.create(recursive: true);

    final destination = File(p.join(dir.path, fileName));
    if (await destination.exists() &&
        await destination.length() >= minimumBytes) {
      return destination.path;
    }

    onStatus?.call('Installing the built-in model (one time)…');

    try {
      await _channel.invokeMethod<void>('installModel', {
        'assetName': assetPath,
        'destPath': destination.path,
      });
    } on MissingPluginException {
      // Desktop fallback. On Android/iOS the native streaming copy is used.
      onStatus?.call('Copying model…');
      final data = await rootBundle.load(assetPath);
      await destination.writeAsBytes(
        data.buffer.asUint8List(),
        flush: true,
      );
    } on PlatformException catch (error) {
      throw Exception(
        'Could not install the model: ${error.message ?? error.code}',
      );
    }

    if (!await destination.exists() ||
        await destination.length() < minimumBytes) {
      throw Exception(
        'The bundled model is missing. Put your GGUF at '
        'flutter_app/assets/models/model.gguf and rebuild. '
        'Run tools/fetch_model.ps1 for the default Qwen2.5-Coder-0.5B model.',
      );
    }

    return destination.path;
  }
}

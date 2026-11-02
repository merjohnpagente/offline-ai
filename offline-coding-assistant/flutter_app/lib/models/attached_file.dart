/// A text or code file the user attached to the current chat.
///
/// The content is injected into the model's system prompt for every turn while
/// the attachment stays active. It is intentionally capped so the file and the
/// conversation still fit inside the on-device context window.
class AttachedFile {
  const AttachedFile({
    required this.name,
    required this.content,
    required this.byteCount,
    required this.truncated,
  });

  final String name;
  final String content;

  /// Size of the file on disk, before the context cap was applied.
  final int byteCount;

  /// True when only the first part of the file was read.
  final bool truncated;

  String get sizeLabel {
    if (byteCount < 1024) return '$byteCount B';
    final kilobytes = byteCount / 1024;
    if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(1)} KB';
    return '${(kilobytes / 1024).toStringAsFixed(1)} MB';
  }
}

import 'dart:math';

final Random _random = Random.secure();

/// Short, collision-resistant id that works without any network or package.
String newId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = _random.nextInt(0x7fffffff).toRadixString(36);
  return '$time$random';
}

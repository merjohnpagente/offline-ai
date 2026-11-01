import 'package:flutter/foundation.dart';

import 'app_database.dart';

/// Generation settings backed by the same local SQLite database as the chats.
class SettingsService extends ChangeNotifier {
  static const double defaultTemperature = 0.2;
  static const int defaultMaxTokens = 512;

  static const String _keyTemperature = 'generation_temperature';
  static const String _keyMaxTokens = 'generation_max_tokens';

  final AppDatabase _database;
  double _temperature;
  int _maxTokens;

  SettingsService._(this._database, this._temperature, this._maxTokens);

  double get temperature => _temperature;
  int get maxTokens => _maxTokens;

  static Future<SettingsService> load(AppDatabase database) async {
    final storedTemperature = await database.getSetting(_keyTemperature);
    final storedMaxTokens = await database.getSetting(_keyMaxTokens);

    final temperature =
        (double.tryParse(storedTemperature ?? '') ?? defaultTemperature)
            .clamp(0.0, 1.0)
            .toDouble();
    final maxTokens = (int.tryParse(storedMaxTokens ?? '') ?? defaultMaxTokens)
        .clamp(64, 2048)
        .toInt();

    return SettingsService._(database, temperature, maxTokens);
  }

  Future<void> setTemperature(double value) async {
    _temperature = value.clamp(0.0, 1.0).toDouble();
    await _database.setSetting(_keyTemperature, _temperature.toString());
    notifyListeners();
  }

  Future<void> setMaxTokens(int value) async {
    _maxTokens = value.clamp(64, 2048).toInt();
    await _database.setSetting(_keyMaxTokens, _maxTokens.toString());
    notifyListeners();
  }

  Future<void> reset() async {
    _temperature = defaultTemperature;
    _maxTokens = defaultMaxTokens;
    await _database.removeSetting(_keyTemperature);
    await _database.removeSetting(_keyMaxTokens);
    notifyListeners();
  }
}

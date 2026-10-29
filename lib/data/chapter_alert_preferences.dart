import 'package:shared_preferences/shared_preferences.dart';

/// Cross-isolate preferences: Android background workers must observe changes
/// made by the foreground app without depending on an in-memory cache.
class ChapterAlertPreferences {
  static const enabledKey = 'senreader.alerts.enabled.v1';
  static const intervalKey = 'senreader.alerts.interval_minutes.v1';
  static const availableIntervals = <int>[30, 60, 180, 360];
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<bool> enabled() async => await _prefs.getBool(enabledKey) ?? false;

  Future<int> intervalMinutes() async {
    final value = await _prefs.getInt(intervalKey) ?? 60;
    return availableIntervals.contains(value) ? value : 60;
  }

  Future<void> setEnabled(bool value) => _prefs.setBool(enabledKey, value);

  Future<void> setIntervalMinutes(int value) {
    if (!availableIntervals.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported interval');
    }
    return _prefs.setInt(intervalKey, value);
  }
}

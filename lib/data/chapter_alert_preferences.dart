import 'package:shared_preferences/shared_preferences.dart';

/// Cross-isolate preferences: Android background workers must observe changes
/// made by the foreground app without depending on an in-memory cache.
class ChapterAlertPreferences {
  static const enabledKey = 'senreader.alerts.enabled.v1';
  static const intervalKey = 'senreader.alerts.interval_minutes.v1';
  static const offerShownKey = 'senreader.alerts.offer_shown.v1';
  static const availableIntervals = <int>[15];
  static const defaultIntervalMinutes = 15;
  SharedPreferencesAsync? _cachedPrefs;
  SharedPreferencesAsync get _prefs => _cachedPrefs ??= SharedPreferencesAsync();

  Future<bool> enabled() async => await _prefs.getBool(enabledKey) ?? false;

  Future<int> intervalMinutes() async {
    final value = await _prefs.getInt(intervalKey);
    final migrated = migrateInterval(value);
    if (value != migrated) await _prefs.setInt(intervalKey, migrated);
    return migrated;
  }

  // The UI now has a single 15-minute schedule; migrate all former choices.
  static int migrateInterval(int? stored) => defaultIntervalMinutes;

  Future<bool> offerShown() async => await _prefs.getBool(offerShownKey) ?? false;
  Future<void> setOfferShown() => _prefs.setBool(offerShownKey, true);

  Future<void> setEnabled(bool value) => _prefs.setBool(enabledKey, value);

  Future<void> setIntervalMinutes(int value) {
    if (!availableIntervals.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported interval');
    }
    return _prefs.setInt(intervalKey, value);
  }
}

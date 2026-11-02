import 'package:shared_preferences/shared_preferences.dart';

/// Cross-isolate preferences: Android background workers must observe changes
/// made by the foreground app without depending on an in-memory cache.
class ChapterAlertPreferences {
  // Legacy setting combined Android notifications with the background scanner.
  static const enabledKey = 'senreader.alerts.enabled.v1';
  static const inAppEnabledKey = 'senreader.updates.in_app_enabled.v2';
  static const systemEnabledKey = 'senreader.updates.android_notifications.v2';
  static const intervalKey = 'senreader.alerts.interval_minutes.v1';
  static const offerShownKey = 'senreader.alerts.offer_shown.v1';
  static const availableIntervals = <int>[15];
  static const defaultIntervalMinutes = 15;
  SharedPreferencesAsync? _cachedPrefs;
  SharedPreferencesAsync get _prefs => _cachedPrefs ??= SharedPreferencesAsync();

  /// Internal inbox scanning is independent of Android's POST_NOTIFICATIONS.
  /// An existing enabled v1 installation keeps its original opt-in.
  Future<bool> enabled() async =>
      await _prefs.getBool(inAppEnabledKey) ??
      await _prefs.getBool(enabledKey) ?? false;

  /// Existing users that opted into v1 keep their previous notification choice.
  /// New users that enable only the internal scanner do not get system alerts.
  Future<bool> systemNotificationsEnabled() async =>
      await _prefs.getBool(systemEnabledKey) ??
      await _prefs.getBool(enabledKey) ?? false;

  Future<void> setSystemNotificationsEnabled(bool value) =>
      _prefs.setBool(systemEnabledKey, value);

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

  Future<void> setEnabled(bool value) => _prefs.setBool(inAppEnabledKey, value);

  Future<void> setIntervalMinutes(int value) {
    if (!availableIntervals.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported interval');
    }
    return _prefs.setInt(intervalKey, value);
  }
}

import 'chapter_alert_preferences.dart';
import 'chapter_background_scheduler.dart';
import 'chapter_notification_service.dart';

/// Permission is requested only by an affirmative offer or Settings action.
class ChapterAlertController {
  ChapterAlertController({ChapterAlertPreferences? preferences,
      Future<bool> Function()? requestPermission, Future<void> Function()? sync})
      : preferences = preferences ?? ChapterAlertPreferences(),
        _requestPermission = requestPermission ?? ChapterNotificationService.instance.askPermission,
        _sync = sync ?? ChapterBackgroundScheduler.sync;

  final ChapterAlertPreferences preferences;
  final Future<bool> Function() _requestPermission;
  final Future<void> Function() _sync;
  bool _offering = false;

  Future<bool> claimOffer() async {
    if (_offering) return false;
    _offering = true;
    try {
      if (await preferences.offerShown()) return false;
      await preferences.setOfferShown();
      return !await preferences.enabled();
    } finally {
      _offering = false;
    }
  }

  /// Enable/disable background discovery for the internal inbox. This does
  /// not request the Android notification permission.
  Future<bool> setEnabled(bool enabled) async {
    await preferences.setOfferShown();
    await preferences.setEnabled(enabled);
    try {
      await _sync();
      return enabled;
    } catch (_) {
      // Keep the settings honest if Android task registration failed.
      if (enabled) await preferences.setEnabled(false);
      rethrow;
    }
  }

  /// OS notification permission is needed only when the user explicitly asks
  /// for external notifications; rejecting it must not disable the in-app inbox.
  Future<bool> setSystemNotificationsEnabled(bool enabled) async {
    if (!enabled) {
      await preferences.setSystemNotificationsEnabled(false);
      return false;
    }
    final allowed = await _requestPermission();
    await preferences.setSystemNotificationsEnabled(allowed);
    return allowed;
  }
}

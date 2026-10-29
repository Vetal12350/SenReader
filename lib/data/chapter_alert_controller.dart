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

  Future<bool> setEnabled(bool enabled) async {
    await preferences.setOfferShown();
    // Fail closed on denial or a plugin/scheduler failure.
    await preferences.setEnabled(false);
    try {
      final allowed = enabled && await _requestPermission();
      await preferences.setEnabled(allowed);
      await _sync();
      return allowed;
    } catch (_) {
      await preferences.setEnabled(false);
      rethrow;
    }
  }
}

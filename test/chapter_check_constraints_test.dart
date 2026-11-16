import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_alert_preferences.dart';
import 'package:senreader/data/chapter_background_scheduler.dart';
import 'package:senreader/data/chapter_scan_runner.dart';
import 'package:workmanager/workmanager.dart';

/// B1: background chapter checks need only a network connection. A
/// battery-not-low requirement silently blocked checks on a partly charged
/// phone and must not come back.
void main() {
  test('chapter check work requires network and nothing battery-related', () {
    final constraints = chapterCheckConstraints();
    expect(constraints.networkType, NetworkType.connected);
    expect(constraints.requiresBatteryNotLow, isNot(true));
    expect(constraints.requiresCharging, isNot(true));
    expect(constraints.requiresDeviceIdle, isNot(true));
  });

  test('worker runs as a dataSync foreground service with a Russian notice', () {
    final config = chapterCheckForeground();
    expect(config.foregroundServiceType, ForegroundServiceType.dataSync);
    expect(config.notificationText, 'Проверка новых глав…');
    expect(config.notificationChannelName, 'Проверка новых глав');
    expect(config.notificationChannelId, isNot('senreader_chapters'),
      reason: 'separate low-noise channel, not the new-chapter channel');
  });

  test('worker covers the queue in one pass; in-app catch-up stays short', () {
    expect(workerScanBudget, greaterThan(appScanBudget));
    expect(workerScanBudget, lessThan(const Duration(minutes: 10)),
      reason: 'stays under the WorkManager limit if foreground is refused');
    expect(appScanBudget, const Duration(seconds: 120));
  });

  test('checks are scheduled hourly, not every 15 minutes', () {
    expect(ChapterAlertPreferences.defaultIntervalMinutes, 60);
    expect(ChapterAlertPreferences.migrateInterval(15), 60);
  });
}

import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog_repository.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_checker.dart';
import 'chapter_notification_service.dart';
import 'chapter_scan_schedule.dart';
import 'library_store.dart';

const chapterCheckWork = 'senreader.periodic.chapter_check';
const chapterCheckUniqueName = 'senreader.chapter-check.unique';

Future<void> _performSmartScan({bool foreground = false}) async {
  final prefs = ChapterAlertPreferences();
  if (!await prefs.enabled()) return;
  final library = LibraryStore();
  await library.load();
  if (library.items.isEmpty) return;
  final profile = library.profileId;
  final report = await ChapterChecker(
    repository: CatalogRepository(), library: library,
    systemNotificationsEnabled: await prefs.systemNotificationsEnabled(),
  ).check(smartSchedule: true);
  // If the user switched Google accounts during a foreground check, never
  // post another profile's notifications.
  await library.load();
  if (library.profileId != profile) return;
  { // Also drain pending OS deliveries left by an earlier worker.
    // Local inbox delivery is independent of the Android notifications plugin.
    // A plugin initialization error must not lose discovered chapters.
    if (await prefs.systemNotificationsEnabled()) {
      try {
        await ChapterNotificationService.instance.initialize(
            captureTaps: foreground);
      } catch (_) {
        // Continue to persist the in-app updates even without system alerts.
      }
    }
    await ChapterNotificationService.instance.postNewChapters(
        report.discoveries);
  }
  await ChapterScanScheduleStore().recordRun(profile,
      ChapterBackgroundScanSummary(
        at: DateTime.now(), checkedSources: report.checkedSources,
        skippedSources: report.skippedSources,
        foundChapters: report.discoveries.length,
        warnings: report.warnings.length,
      ));
}

@pragma('vm:entry-point')
void chapterWorkDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != chapterCheckWork) return true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await _performSmartScan();
      return true;
    } catch (_) {
      // Native WorkManager retries transient failures. Reading remains usable.
      return false;
    }
  });
}

/// A single periodic Android task, never one task per saved title.
/// A 15-minute schedule is opportunistic; actual per-title checks are staggered.
class ChapterBackgroundScheduler {
  static bool _initialized = false;
  static bool _catchUpActive = false;

  static Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (!_initialized) {
      await Workmanager().initialize(chapterWorkDispatcher);
      _initialized = true;
    }
    await sync();
  }

  /// Catch up when the app opens or resumes: no full-library scan on every
  /// gesture. The same on-device schedule avoids duplicate requests.
  static Future<void> checkOnResume() async {
    if (defaultTargetPlatform != TargetPlatform.android || _catchUpActive) {
      return;
    }
    _catchUpActive = true;
    try {
      // Let WorkManager's background isolate perform parsing and database work.
      // First-frame rendering never waits for a scan or its network requests.
      await initialize();
      await Workmanager().registerOneOffTask(
        'senreader.chapter-catchup.unique', chapterCheckWork,
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected,
          requiresBatteryNotLow: true),
      );
    } catch (_) {
      // Background work must not interfere with the foreground reader.
    } finally {
      _catchUpActive = false;
    }
  }

  static Future<void> sync() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final settings = ChapterAlertPreferences();
    if (!await settings.enabled()) {
      await Workmanager().cancelByUniqueName(chapterCheckUniqueName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      chapterCheckUniqueName,
      chapterCheckWork,
      frequency: Duration(minutes: await settings.intervalMinutes()),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}



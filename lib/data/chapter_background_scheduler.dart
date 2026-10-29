import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog_repository.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_checker.dart';
import 'chapter_notification_service.dart';
import 'library_store.dart';

const chapterCheckWork = 'senreader.periodic.chapter_check';
const chapterCheckUniqueName = 'senreader.chapter-check.unique';

@pragma('vm:entry-point')
void chapterWorkDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != chapterCheckWork) return true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      final settings = ChapterAlertPreferences();
      if (!await settings.enabled()) return true;
      final library = LibraryStore();
      await library.load();
      if (library.items.isEmpty) return true;
      final report = await ChapterChecker(
        repository: CatalogRepository(), library: library,
      ).check();
      if (report.discoveries.isNotEmpty) {
        await ChapterNotificationService.instance.initialize(captureTaps: false);
        await ChapterNotificationService.instance.postNewChapters(report.discoveries);
      }
      return true;
    } catch (_) {
      // Native WorkManager can reschedule transient failures. Do not clear
      // saved baselines or leak source responses to Android logs.
      return false;
    }
  });
}

/// A single periodic Android task, never one task per saved title.
/// WorkManager is opportunistic, not an instant publication-time push service.
class ChapterBackgroundScheduler {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (!_initialized) {
      await Workmanager().initialize(chapterWorkDispatcher);
      _initialized = true;
    }
    await sync();
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

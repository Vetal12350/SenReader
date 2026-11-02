import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'catalog_repository.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_checker.dart';
import 'chapter_notification_service.dart';
import 'chapter_scan_schedule.dart';
import 'library_store.dart';

/// Shared bounded automatic path for WorkManager and foreground catch-up.
/// Persistence/leases and source limits are identical in both entry points.
class ChapterScanRunner {
  ChapterScanRunner({ChapterAlertPreferences? preferences, LibraryStore? library,
    CatalogRepository? repository, this.scan, this.deliver})
      : preferences = preferences ?? ChapterAlertPreferences(),
        library = library ?? LibraryStore(),
        repository = repository ?? CatalogRepository();
  final ChapterAlertPreferences preferences;
  final LibraryStore library;
  final CatalogRepository repository;
  final Future<ChapterScanReport> Function(ChapterChecker)? scan;
  final Future<void> Function(List<ChapterDiscovery>)? deliver;

  static Future<String> activeProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(LibraryStore.activeProfileKey) ?? '';
  }

  Future<bool> run({String origin = 'workmanager'}) async {
    final schedule = ChapterScanScheduleStore();
    final at = DateTime.now();
    final profile = await activeProfile();
    var latest = const ChapterScanReport([], [], 0);
    Future<void> record(String outcome, String reason) => schedule.recordRun(profile,
      ChapterBackgroundScanSummary(at: at, checkedSources: latest.checkedSources,
        skippedSources: latest.skippedSources, foundChapters: latest.discoveries.length,
        warnings: latest.warnings.length, outcome: outcome, reason: reason,
        origin: origin, nextEligibleAt: latest.nextEligibleAt));
    try {
      // A killed isolate leaves "running", not yesterday's misleading success.
      await record('running', '');
      if (!await preferences.enabled()) {
        await record('skipped', 'disabled');
        return true;
      }
      await library.load();
      if (library.profileId != profile) {
        await record('skipped', 'profile_changed');
        return true;
      }
      final checker = ChapterChecker(repository: repository, library: library,
        systemNotificationsEnabled: await preferences.systemNotificationsEnabled(),
        onProgress: (report) async {
          latest = report;
          await record('running', '');
        });
      latest = await (scan?.call(checker) ?? checker.check(smartSchedule: true));
      await library.load();
      if (library.profileId != profile) {
        await record('skipped', 'profile_changed');
        return true;
      }
      // Checker has already committed the inbox. Optional OS delivery cannot
      // turn successful discovery into a failed scan or prevent its summary.
      final outcome = latest.warnings.isNotEmpty ? 'partial' :
          latest.checkedSources == 0 ? 'skipped' : 'success';
      await record(outcome, latest.reason);
      if (await preferences.systemNotificationsEnabled()) {
        try {
          if (deliver != null) {
            await deliver!(latest.discoveries).timeout(const Duration(seconds: 10));
          } else {
            await ChapterNotificationService.instance.initialize(
              captureTaps: origin == 'app').timeout(const Duration(seconds: 10));
            // #125: drain explicit pending intent even with no new discoveries;
            // do not reinsert stale/read/hidden discoveries into the inbox.
            await ChapterNotificationService.instance.postNewChapters(const [])
                .timeout(const Duration(seconds: 10));
          }
        } catch (_) { /* Pending OS intent remains retryable in SQLite v4. */ }
      }
      return true;
    } catch (_) {
      await record('error', 'scan_error');
      return false;
    }
  }
}

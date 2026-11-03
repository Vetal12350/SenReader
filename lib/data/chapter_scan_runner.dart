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
    CatalogRepository? repository, ChapterScanScheduleStore? schedule, this.scan, this.deliver})
      : preferences = preferences ?? ChapterAlertPreferences(),
        library = library ?? LibraryStore(),
        repository = repository ?? CatalogRepository(),
        schedule = schedule ?? ChapterScanScheduleStore();
  final ChapterAlertPreferences preferences;
  final LibraryStore library;
  final CatalogRepository repository;
  final ChapterScanScheduleStore schedule;
  final Future<ChapterScanReport> Function(ChapterChecker)? scan;
  final Future<void> Function(List<ChapterDiscovery>)? deliver;

  static Future<String> activeProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(LibraryStore.activeProfileKey) ?? '';
  }

  Future<bool> run({String origin = 'workmanager'}) async {
    final at = DateTime.now();
    final profile = await activeProfile();
    var latest = const ChapterScanReport([], [], 0);
    var runId = 0;
    DateTime? finishedAt;
    var systemDelivery = 'disabled';
    var postedNotifications = 0;
    ChapterBackgroundScanSummary summary(String outcome, String reason) =>
      ChapterBackgroundScanSummary(at: at, runId: runId,
        finishedAt: outcome == 'running' ? null : (finishedAt ??= DateTime.now()),
        checkedSources: latest.checkedSources, skippedSources: latest.skippedSources,
        availableSources: latest.availableSources, successfulSources: latest.successfulSources,
        failedSources: latest.failedSources, skipReasons: latest.skipReasons,
        chapterDecisions: latest.chapterDecisions,
        foundChapters: latest.discoveries.length, warnings: latest.warnings.length,
        outcome: outcome, reason: reason, origin: origin,
        systemDelivery: systemDelivery, postedNotifications: postedNotifications,
        nextEligibleAt: latest.nextEligibleAt);
    Future<void> record(String outcome, String reason) => schedule.recordRun(profile, summary(outcome, reason));
    try {
      runId = await schedule.beginRun(profile, summary('running', ''));
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
      final wantsSystem = await preferences.systemNotificationsEnabled();
      systemDelivery = wantsSystem ? 'pending' : 'disabled';
      await record(outcome, latest.reason);
      if (wantsSystem) {
        try {
          if (deliver != null) {
            await deliver!(latest.discoveries).timeout(const Duration(seconds: 10));
            systemDelivery = 'attempted';
          } else {
            await ChapterNotificationService.instance.initialize(
              captureTaps: origin == 'app').timeout(const Duration(seconds: 10));
            // #125: drain explicit pending intent even with no new discoveries;
            // do not reinsert stale/read/hidden discoveries into the inbox.
            final service = ChapterNotificationService.instance;
            if (await service.hasPermission().timeout(const Duration(seconds: 5))) {
              postedNotifications = await service.postNewChapters(const [])
                  .timeout(const Duration(seconds: 10));
              systemDelivery = 'processed';
            } else {
              systemDelivery = 'permission_denied';
            }
          }
        } catch (_) {
          systemDelivery = 'error'; // Pending intent stays retryable in SQLite v4.
        }
        await record(outcome, latest.reason);
      }
      return true;
    } catch (_) {
      await schedule.recordBootstrapFailure(profile, summary('error', 'scan_error'));
      return false;
    }
  }
}

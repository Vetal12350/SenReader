import 'dart:async';
import 'chapter_scan_trace.dart';
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

  Future<ChapterScanReport> checkManual({bool diagnostics = false}) =>
      ChapterScanTrace().run('manual', () => _checkManual(diagnostics: diagnostics));

  Future<ChapterScanReport> _checkManual({bool diagnostics = false}) async {
    await ChapterScanTrace.stage('library_load', library.load);
    final profile = library.profileId;
    final system = await ChapterScanTrace.stage('preferences_enabled', preferences.enabled) && await ChapterScanTrace.stage('preferences_system', preferences.systemNotificationsEnabled);
    final report = await ChapterScanTrace.stage('scan', () => ChapterChecker(
      repository: repository, library: library, systemNotificationsEnabled: system)
      .check(diagnostics: diagnostics));
    ChapterScanTrace.current?.event('scan_result',
      report.reason.isEmpty ? 'success' : report.reason);
    if (system && profile == await ChapterScanTrace.stage('profile_load', activeProfile)) {
      try {
        await ChapterScanTrace.stage('notifications_post', () =>
          ChapterNotificationService.instance.postNewChapters(const [])
            .timeout(const Duration(seconds: 10)));
      } catch (_) {
        // The durable inbox remains available even if Android delivery fails.
      }
    }
    return report;
  }

  /// [shouldStop] is checked between title/source pairs (foreground only).
  Future<bool> run({String origin = 'workmanager', bool Function()? shouldStop}) =>
      (ChapterScanTrace.current ?? ChapterScanTrace()).run(
        origin == 'app' ? 'app' : 'workmanager',
        () => _run(origin: origin, shouldStop: shouldStop));

  Future<bool> _run({required String origin, bool Function()? shouldStop}) async {
    final at = DateTime.now();
    final profile = await ChapterScanTrace.stage('profile_load', activeProfile);
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
        foundChapters: latest.discoveries.length, updatedTitles: latest.updatedTitles,
        warnings: latest.warnings.length,
        outcome: outcome, reason: reason, origin: origin,
        systemDelivery: systemDelivery, postedNotifications: postedNotifications,
        nextEligibleAt: latest.nextEligibleAt);
    Future<void> record(String outcome, String reason) => ChapterScanTrace.stage('run_record',
        () async {
          await schedule.recordRun(profile, summary(outcome, reason));
          if (outcome != 'running') {
            ChapterScanTrace.current?.event('scan_result',
              reason.isEmpty ? outcome : '${outcome}_$reason');
          }
        });
    try {
      runId = await ChapterScanTrace.stage('run_insert',
        () => schedule.beginRun(profile, summary('running', '')));
      if (!await ChapterScanTrace.stage('preferences_enabled', preferences.enabled)) {
        await record('skipped', 'disabled');
        return true;
      }
      if (shouldStop?.call() ?? false) {
        // Reader open: avoid even the library decode on the shared thread.
        await record('skipped', 'reader_active');
        return true;
      }
      await ChapterScanTrace.stage('library_load', library.load);
      if (library.profileId != profile) {
        await record('skipped', 'profile_changed');
        return true;
      }
      final checker = ChapterChecker(repository: repository, library: library,
        systemNotificationsEnabled: await ChapterScanTrace.stage('preferences_system', preferences.systemNotificationsEnabled),
        onProgress: (report) async {
          latest = report;
          await record('running', '');
        });
      latest = await ChapterScanTrace.stage('scan',
        () => scan?.call(checker) ??
          checker.check(smartSchedule: true, shouldStop: shouldStop));
      await ChapterScanTrace.stage('library_load', library.load);
      if (library.profileId != profile) {
        await record('skipped', 'profile_changed');
        return true;
      }
      // Checker has already committed the inbox. Optional OS delivery cannot
      // turn successful discovery into a failed scan or prevent its summary.
      final outcome = latest.warnings.isNotEmpty ? 'partial' :
          latest.checkedSources == 0 ? 'skipped' : 'success';
      final wantsSystem = await ChapterScanTrace.stage('preferences_system', preferences.systemNotificationsEnabled);
      systemDelivery = wantsSystem ? 'pending' : 'disabled';
      await record(outcome, latest.reason);
      if (wantsSystem) {
        try {
          if (deliver != null) {
            await deliver!(latest.discoveries).timeout(const Duration(seconds: 10));
            systemDelivery = 'attempted';
          } else {
            await ChapterScanTrace.stage('notifications_init', () =>
              ChapterNotificationService.instance.initialize(captureTaps: origin == 'app')
                .timeout(const Duration(seconds: 10)));
            // #125: drain explicit pending intent even with no new discoveries;
            // do not reinsert stale/read/hidden discoveries into the inbox.
            final service = ChapterNotificationService.instance;
            if (!await ChapterScanTrace.stage('notifications_permission',
              () => service.hasPermission().timeout(const Duration(seconds: 5)))) {
              systemDelivery = 'permission_denied';
            } else if (!await ChapterScanTrace.stage('notifications_channel',
              () => service.channelEnabled().timeout(const Duration(seconds: 5)))) {
              systemDelivery = 'channel_disabled';
            } else {
              postedNotifications = await ChapterScanTrace.stage('notifications_post',
                () => service.postNewChapters(const []).timeout(const Duration(seconds: 10)));
              systemDelivery = postedNotifications > 0 ? 'processed' : 'nothing_posted';
            }
          }
        } catch (_) {
          systemDelivery = 'error'; // Pending intent stays retryable in SQLite v4.
        }
        await record(outcome, latest.reason);
      }
      return !(latest.successfulSources == 0 && latest.failedSources > 0 &&
          (latest.reason == 'source_error' || latest.reason == 'timeout'));
    } catch (_) {
      ChapterScanTrace.current?.event('scan_result', 'scan_error');
      await ChapterScanTrace.stage('bootstrap_record',
        () => schedule.recordBootstrapFailure(profile, summary('error', 'scan_error')));
      return false;
    }
  }
}

import 'dart:async';
import 'chapter_scan_trace.dart';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_scan_runner.dart';
import 'chapter_scan_schedule.dart';

const chapterCheckWork = 'senreader.periodic.chapter_check';
const chapterCheckUniqueName = 'senreader.chapter-check.unique';
const chapterCatchUpUniqueName = 'senreader.chapter-catchup.unique';

@pragma('vm:entry-point')
void chapterWorkDispatcher() {
  ChapterScanTrace().event('dispatcher_entry', 'begin');
  final active = <ChapterScanTrace>{};
  Workmanager().executeTask((task, data) async {
    if (task != chapterCheckWork) return true;
    final trace = ChapterScanTrace();
    active.add(trace);
    try {
      return await trace.run('dispatch', () async {
        await trace.step('plugin_bootstrap', () async {
          WidgetsFlutterBinding.ensureInitialized();
          DartPluginRegistrant.ensureInitialized();
        });
        final success = await ChapterScanRunner().run();
        trace.event('worker_result', success ? 'success' : 'retry');
        return success;
      });
    } catch (_) {
      // Plugin/bootstrap failure may precede the runner. Best-effort recording:
      // if preferences themselves are unavailable no Dart record is possible.
      try {
        await trace.step('dispatcher_failure_record', () async => ChapterScanScheduleStore().recordBootstrapFailure(await trace.step('failure_profile_load', ChapterScanRunner.activeProfile),
          ChapterBackgroundScanSummary(at: DateTime.now(), checkedSources: 0,
            skippedSources: 0, foundChapters: 0, warnings: 1,
            outcome: 'error', reason: 'plugin_error', finishedAt: DateTime.now())));
      } catch (_) {}
      trace.event('worker_result', 'retry');
      return false;
    } finally {
      active.remove(trace);
    }
  }, onTaskStopped: (task, reason) async {
    if (task != chapterCheckWork) return;
    // Each background engine owns this set. Associate only an unambiguous
    // active invocation; never borrow an ID from another isolate/worker.
    if (active.length == 1) {
      active.single.androidStopped(reason.name);
    } else {
      ChapterScanTrace().event('worker_stop_unattributed', reason.name);
    }
  });
}

/// A resume must not depend on native registration or Firebase completing.
/// SQLite claims and provider gates arbitrate simultaneous workers.
class ChapterResumeCatchUp {
  ChapterResumeCatchUp({required this.register, required this.scan});
  final Future<void> Function() register, scan;
  Future<void>? _active;

  Future<void> run() {
    final active = _active;
    if (active != null) return active;
    // Schedule native continuation independently. Reading/first frame never
    // awaits either this registration or the bounded async network scan.
    unawaited(Future<void>.sync(register).catchError((Object _) {}));
    return _active = Future<void>.sync(scan).whenComplete(() { _active = null; });
  }
}

/// One opportunistic periodic task; no timer/task per saved title.
class ChapterBackgroundScheduler {
  static Future<void>? _initialization;
  static final _catchUp = ChapterResumeCatchUp(register: _registerCatchUp,
    scan: () async { await ChapterScanRunner().run(origin: 'app'); });

  static Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _initialization ??= Workmanager().initialize(chapterWorkDispatcher);
      await _initialization;
    } catch (_) {
      _initialization = null; // Retry initialization on a later resume.
      await _registration(false);
      rethrow;
    }
    await sync();
  }

  static Future<void> _registration(bool success) async {
    try {
      await ChapterScanScheduleStore().recordRegistration(
        await ChapterScanRunner.activeProfile(), success: success);
    } catch (_) {}
  }

  static Future<void> checkOnResume() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try { await _catchUp.run(); }
    catch (_) { /* Runner/bootstrap errors must never block the reader. */ }
  }

  static Future<void> _registerCatchUp() async {
    try {
      await initialize();
      if (!await ChapterAlertPreferences().enabled()) return;
      await Workmanager().registerOneOffTask(
        chapterCatchUpUniqueName, chapterCheckWork,
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 5),
        constraints: Constraints(networkType: NetworkType.connected,
          requiresBatteryNotLow: true),
      );
      await _registration(true);
    } catch (_) {
      await _registration(false);
    }
  }

  static Future<void> sync() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final settings = ChapterAlertPreferences();
      if (!await settings.enabled()) {
        await Workmanager().cancelByUniqueName(chapterCheckUniqueName);
        await Workmanager().cancelByUniqueName(chapterCatchUpUniqueName);
        return;
      }
      await Workmanager().registerPeriodicTask(
        chapterCheckUniqueName, chapterCheckWork,
        frequency: Duration(minutes: await settings.intervalMinutes()),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 5),
        constraints: Constraints(networkType: NetworkType.connected,
          requiresBatteryNotLow: true),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
      await _registration(true);
    } catch (_) {
      await _registration(false);
      rethrow;
    }
  }
}



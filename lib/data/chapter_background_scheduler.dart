import 'dart:async';
import 'chapter_scan_trace.dart';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'chapter_alert_preferences.dart';
import 'chapter_scan_runner.dart';
import 'chapter_scan_schedule.dart';
import 'reader_activity.dart';

const chapterCheckWork = 'senreader.periodic.chapter_check';
const chapterCheckUniqueName = 'senreader.chapter-check.unique';
const chapterCatchUpUniqueName = 'senreader.chapter-catchup.unique';

/// Only network is required. `requiresBatteryNotLow` was dropped (B1): on a
/// phone that is often below ~15-20 % it silently held every periodic and
/// catch-up check. Android's own Doze/standby limits still apply.
Constraints chapterCheckConstraints() =>
    Constraints(networkType: NetworkType.connected);

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
  ChapterResumeCatchUp({required this.register, required this.scan,
    this.readerOpen, this.delay = Duration.zero});
  final Future<void> Function() register, scan;
  /// Open reader screens. While positive, the UI-isolate scan is deferred
  /// until the reader closes; the native one-off task is still registered.
  final ValueListenable<int>? readerOpen;
  /// Lets the first frames/reader opening settle before foreground parsing.
  final Duration delay;
  Future<void>? _active;
  VoidCallback? _waitingForReaderClose;

  bool get _reading => (readerOpen?.value ?? 0) > 0;

  Future<void> run() {
    final active = _active;
    if (active != null) return active;
    // Schedule native continuation independently. Reading/first frame never
    // awaits either this registration or the bounded async network scan.
    unawaited(Future<void>.sync(register).catchError((Object _) {}));
    return _active = _gatedScan().whenComplete(() { _active = null; });
  }

  Future<void> _gatedScan() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (_reading) {
      _deferUntilReaderCloses();
      return;
    }
    await scan();
  }

  void _deferUntilReaderCloses() {
    final notifier = readerOpen;
    if (notifier == null || _waitingForReaderClose != null) return;
    void listener() {
      if (notifier.value > 0) return;
      notifier.removeListener(listener);
      _waitingForReaderClose = null;
      unawaited(run().catchError((Object _) {}));
    }
    _waitingForReaderClose = listener;
    notifier.addListener(listener);
  }
}

/// One opportunistic periodic task; no timer/task per saved title.
class ChapterBackgroundScheduler {
  static Future<void>? _initialization;
  static final _catchUp = ChapterResumeCatchUp(register: _registerCatchUp,
    readerOpen: ReaderActivity.open, delay: const Duration(seconds: 20),
    // A reader opened mid-scan stops it before the next title; unchecked
    // titles stay due in the SQLite queue for WorkManager or the next resume.
    scan: () async { await ChapterScanRunner().run(origin: 'app',
      shouldStop: () => ReaderActivity.isOpen); });

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
        constraints: chapterCheckConstraints(),
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
        constraints: chapterCheckConstraints(),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
      await _registration(true);
    } catch (_) {
      await _registration(false);
      rethrow;
    }
  }
}



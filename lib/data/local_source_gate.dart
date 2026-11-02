import 'package:sqflite/sqflite.dart';
import 'dart:async';
import 'chapter_scan_queue.dart';
import 'senkuro_request_gate.dart';

/// Coordinates *automatic background chapter scans* across isolates/UIDs.
/// Foreground, user-initiated catalog/reader requests retain their existing
/// source-specific behavior and must not be blocked by a background 403 lease.
/// Neither path may bypass a provider's HTTP restrictions or CAPTCHA.
class LocalSourceGate {
  LocalSourceGate(this.source);
  final String source;
  static const deadlineKey = #senreaderScanDeadline;
  static const backgroundScanKey = #senreaderBackgroundChapterScan;

  /// A zone belongs to the scheduled scanner, not the entire app/isolate.
  /// The foreground reader must never inherit another task's cooldown.
  static bool get isBackgroundScan =>
      Zone.current[backgroundScanKey] == true;

  /// Apply the shared persistent gate only to automatic background checks.
  /// Calls from the reader/catalog take the pre-existing provider path;
  /// any HTTP 403/429 they receive is still reported, never bypassed.
  static Future<T> runScoped<T>(String provider,
      Future<T> Function() request,
      {Future<T> Function()? foreground}) {
    return isBackgroundScan
        ? LocalSourceGate(provider).run(request)
        : (foreground ?? request)();
  }
  static bool get expired {
    final deadline = Zone.current[deadlineKey] as bool Function()?;
    return deadline?.call() ?? false;
  }
  Future<T> run<T>(Future<T> Function() request) async {
    final db = await ChapterScanQueue().database();
    int? token;
    while (token == null) {
      if (expired) throw TimeoutException('Scan budget exhausted');
      final now = DateTime.now().millisecondsSinceEpoch;
      final result = await db.transaction((t) async {
        await t.insert('providers', {'source': source},
          conflictAlgorithm: ConflictAlgorithm.ignore);
        final row = (await t.query('providers', where: 'source = ?',
          whereArgs: [source])).single;
        final ready = (row['next'] as int) > (row['lease'] as int)
            ? row['next'] as int : row['lease'] as int;
        if ((row['next'] as int) > now + 5000) {
          throw StateError('$source cooldown');
        }
        if (ready > now) return -ready;
        final nextToken = (row['token'] as int) + 1;
        await t.update('providers', {'token': nextToken, 'lease': now + 60000},
          where: 'source = ?', whereArgs: [source]);
        return nextToken;
      });
      if (result > 0) { token = result; break; }
      final delay = Duration(milliseconds: -result - now);
      // Never occupy a worker waiting for a provider cooldown.
      await Future<void>.delayed(delay > const Duration(milliseconds: 200)
          ? const Duration(milliseconds: 200) : delay);
    }
    try {
      if (expired) throw TimeoutException('Scan budget exhausted');
      return await request();
    } finally {
      await db.rawUpdate('UPDATE providers SET lease = 0, next = MAX(next, ?) '
        'WHERE source = ? AND token = ?',
        [DateTime.now().millisecondsSinceEpoch + 2000, source, token]);
    }
  }
  Future<void> response(int status, String? retryAfter) async {
    if (status != 429 && status != 403) return;
    final delay = status == 403 ? const Duration(hours: 24) :
        SenkuroRequestGate.parseRetryAfter(retryAfter) ?? const Duration(minutes: 30);
    final db = await ChapterScanQueue().database();
    await db.rawUpdate('UPDATE providers SET next = MAX(next, ?) WHERE source = ?',
      [DateTime.now().add(delay < const Duration(minutes: 1)
          ? const Duration(minutes: 1) : delay).millisecondsSinceEpoch, source]);
  }
}

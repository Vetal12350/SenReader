import 'package:sqflite/sqflite.dart';
import 'dart:async';
import 'chapter_scan_queue.dart';
import 'senkuro_request_gate.dart';

/// Shared by every production HTTP caller on the device, across isolates/UIDs.
/// Delays are conservative implementation defaults, not a claim of permission.
class LocalSourceGate {
  LocalSourceGate(this.source);
  final String source;
  static const deadlineKey = #senreaderScanDeadline;
  static bool get expired {
    final deadline = Zone.current[deadlineKey] as DateTime?;
    return deadline != null && !DateTime.now().isBefore(deadline);
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

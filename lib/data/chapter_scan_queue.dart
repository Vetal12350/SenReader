import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'chapter_inbox_store.dart';
import 'chapter_scan_schedule.dart';

/// Durable device-local work, independent of reading history and OS alerts.
class ScanJob {
  ScanJob(this.book, this.source, this.id);
  final String book, source, id;
  String get key => jsonEncode([book, source, id]);
}
class ScanLease {
  ScanLease(this.job, this.token);
  final ScanJob job;
  final int token;
}
class ScanQueueStatus {
  ScanQueueStatus(this.reason, this.nextEligibleAt, [this.jobReasons = const {}]);
  final String reason;
  final DateTime? nextEligibleAt;
  final Map<String, String> jobReasons;
}
class ChapterScanQueue {
  Future<Database> database() async => openDatabase(
      ChapterInboxStore.databasePathOverride == null
          ? '${await getDatabasesPath()}/senreader_scan_queue.db'
          : '${ChapterInboxStore.databasePathOverride}.queue',
      version: 2, onCreate: (db, _) async {
    await db.execute('CREATE TABLE jobs (profile TEXT, key TEXT, book TEXT, '
      'source TEXT, sourceId TEXT, due INTEGER DEFAULT 0, turn INTEGER DEFAULT 0, '
      'lease INTEGER DEFAULT 0, token INTEGER DEFAULT 0, PRIMARY KEY(profile,key))');
    await db.execute('CREATE TABLE providers (source TEXT PRIMARY KEY, '
      'next INTEGER DEFAULT 0, lease INTEGER DEFAULT 0, token INTEGER DEFAULT 0)');
    await _createRuns(db);
  }, onUpgrade: (db, old, _) async {
    if (old < 2) await _createRuns(db);
  });

  static Future<void> _createRuns(Database db) async {
    await db.execute('CREATE TABLE scan_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'profile TEXT NOT NULL, origin TEXT NOT NULL, started INTEGER NOT NULL, '
      'updated INTEGER NOT NULL, expires INTEGER NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL)');
    await db.execute('CREATE INDEX scan_runs_origin ON scan_runs(profile, origin, id DESC)');
  }

  Future<void> reconcile(String profile, List<ScanJob> jobs) async {
    final db = await database();
    final old = await ChapterScanScheduleStore().load(profile);
    await db.transaction((t) async {
      final keys = jobs.map((j) => j.key).toSet();
      for (final row in await t.query('jobs', where: 'profile = ?', whereArgs: [profile])) {
        if (!keys.contains(row['key'])) await t.delete('jobs',
          where: 'profile = ? AND key = ?', whereArgs: [profile, row['key']]);
      }
      for (final j in jobs) {
        await t.insert('jobs', {'profile': profile, 'key': j.key,
          'book': j.book, 'source': j.source, 'sourceId': j.id,
          'due': old[j.key] == null ? 0 : old[j.key]! + 1800000,
          'turn': old[j.key] ?? 0},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }
  Future<ScanLease?> claim(String profile, String source, int now,
      {ScanJob? manualJob}) async {
    final db = await database();
    return db.transaction((t) async {
      if (manualJob == null) {
        final state = await t.query('providers', where: 'source = ?', whereArgs: [source]);
        if (state.isNotEmpty && (state.single['next'] as int) > now + 5000) return null;
        if (state.isNotEmpty && (state.single['lease'] as int) > now + 5000) return null;
      } else {
        await t.insert('jobs', {'profile': profile, 'key': manualJob.key,
          'book': manualJob.book, 'source': manualJob.source, 'sourceId': manualJob.id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final rows = await t.query('jobs', where:
        'profile = ? AND source = ? AND lease <= ? AND ${manualJob == null ? 'due <= ?' : 'key = ?'}',
        whereArgs: [profile, source, now, manualJob?.key ?? now], orderBy: 'turn, key', limit: 1);
      if (rows.isEmpty) return null;
      final row = rows.single;
      final token = (row['token'] as int) + 1;
      // Reserve before network I/O; a killed worker leaves only a finite lease.
      await t.update('jobs', {'token': token, 'lease': now + 300000, 'turn': now},
        where: 'profile = ? AND key = ?', whereArgs: [profile, row['key']]);
      return ScanLease(ScanJob(row['book'] as String, source,
          row['sourceId'] as String), token);
    });
  }
  /// [successDelay]: when the title's release rhythm says the next chapter
  /// is not due soon, a successful check may be followed by a longer pause.
  Future<void> finish(String profile, ScanLease lease, int now,
      {required bool success, Duration? successDelay}) async {
    final db = await database();
    final delay = success ? (successDelay?.inMilliseconds ?? 1800000) : 300000;
    await db.rawUpdate('UPDATE jobs SET lease = 0, due = MAX(due, ?) '
      'WHERE profile = ? AND key = ? AND token = ?',
      [now + delay, profile, lease.job.key, lease.token]);
  }

  /// Manual attempts and automatic work share one due time. Do not take an
  /// active worker's lease or token; its fenced completion remains authoritative.
  Future<void> recordManualAttempt(String profile, ScanJob job, int now,
      {required bool success}) async {
    final db = await database();
    final due = now + (success ? 1800000 : 300000);
    await db.transaction((t) async {
      await t.insert('jobs', {'profile': profile, 'key': job.key,
        'book': job.book, 'source': job.source, 'sourceId': job.id,
        'due': due, 'turn': now}, conflictAlgorithm: ConflictAlgorithm.ignore);
      await t.rawUpdate('UPDATE jobs SET due = MAX(due, ?), '
        'turn = CASE WHEN lease <= ? THEN ? ELSE turn END '
        'WHERE profile = ? AND key = ?', [due, now, now, profile, job.key]);
    });
  }

  Future<ScanQueueStatus> status(String profile, int now) async {
    final rows = await (await database()).rawQuery(
      'SELECT j.key, j.due, j.lease, COALESCE(p.next,0) AS providerNext, '
      'COALESCE(p.lease,0) AS providerLease '
      'FROM jobs j LEFT JOIN providers p ON j.source = p.source WHERE j.profile = ?',
      [profile]);
    if (rows.isEmpty) return ScanQueueStatus('no_reading', null);
    var earliest = 0x7fffffffffffffff;
    var reason = 'interval';
    final reasons = <String, String>{};
    for (final row in rows) {
      final due = row['due'] as int;
      final lease = row['lease'] as int;
      final provider = row['providerNext'] as int;
      final providerLease = row['providerLease'] as int;
      var ready = due;
      var cause = 'interval';
      if (lease > ready) { ready = lease; cause = 'lease'; }
      if (providerLease > now + 5000 && providerLease > ready) {
        ready = providerLease; cause = 'lease';
      }
      // Match claim(): its normal two-second request spacing can be awaited;
      // a longer provider restriction must never occupy a worker waiting.
      if (provider > now + 5000 && provider > ready) {
        ready = provider; cause = 'cooldown';
      }
      if (ready <= now) { ready = now; cause = 'budget'; }
      reasons[row['key'] as String] = cause;
      if (ready < earliest) { earliest = ready; reason = cause; }
    }
    return ScanQueueStatus(reason, DateTime.fromMillisecondsSinceEpoch(earliest), reasons);
  }
}


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
class ChapterScanQueue {
  Future<Database> database() async => openDatabase(
      ChapterInboxStore.databasePathOverride == null
          ? '${await getDatabasesPath()}/senreader_scan_queue.db'
          : '${ChapterInboxStore.databasePathOverride}.queue',
      version: 1, onCreate: (db, _) async {
    await db.execute('CREATE TABLE jobs (profile TEXT, key TEXT, book TEXT, '
      'source TEXT, sourceId TEXT, due INTEGER DEFAULT 0, turn INTEGER DEFAULT 0, '
      'lease INTEGER DEFAULT 0, token INTEGER DEFAULT 0, PRIMARY KEY(profile,key))');
    await db.execute('CREATE TABLE providers (source TEXT PRIMARY KEY, '
      'next INTEGER DEFAULT 0, lease INTEGER DEFAULT 0, token INTEGER DEFAULT 0)');
  });

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
  Future<ScanLease?> claim(String profile, String source, int now) async {
    final db = await database();
    return db.transaction((t) async {
      final state = await t.query('providers', where: 'source = ?', whereArgs: [source]);
      if (state.isNotEmpty && (state.single['next'] as int) > now + 5000) return null;
      final rows = await t.query('jobs', where:
        'profile = ? AND source = ? AND due <= ? AND lease <= ?',
        whereArgs: [profile, source, now, now], orderBy: 'turn, key', limit: 1);
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
  Future<void> finish(String profile, ScanLease lease, int now,
      {required bool success}) async {
    final db = await database();
    await db.update('jobs', {'lease': 0, 'due': now + (success ? 1800000 : 300000)},
      where: 'profile = ? AND key = ? AND token = ?',
      whereArgs: [profile, lease.job.key, lease.token]);
  }
}

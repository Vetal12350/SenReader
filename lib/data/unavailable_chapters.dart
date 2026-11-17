import 'dart:async';
import 'package:sqflite/sqflite.dart';
import '../core/source.dart';
import 'chapter_scan_queue.dart';

/// Chapters a source lists but does not serve (HTTP 404/410, "not public"),
/// so automatic scans stop re-requesting them every run.
///
/// Measured overnight on Pixel: ~180 identical ReadManga `page_404` checks,
/// each costing a gated request and part of the 6-minute worker budget, so
/// the queue never completed. Transient failures (network, timeout, 403/429)
/// are not recorded here and keep their existing retry behavior.
class UnavailableChapters {
  UnavailableChapters({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  static const firstBackoff = Duration(hours: 6);
  static const maxBackoff = Duration(hours: 24);

  /// True for errors that mean "this chapter is not served", not "try again".
  static bool isPersistent(Object error) {
    if (error is! SourceException) return false;
    final text = error.message.toLowerCase();
    return RegExp(r'http\s+(404|410)\b').hasMatch(text) ||
        text.contains('публичном доступе') || text.contains('заглушк') ||
        text.contains('одинаковая картинка');
  }

  // Lazily created in the existing queue database: additive, no version bump.
  Future<Database> _db() async {
    final db = await ChapterScanQueue().database();
    await db.execute('CREATE TABLE IF NOT EXISTS unavailable_chapters ('
        'profile TEXT NOT NULL, pair TEXT NOT NULL, chapter TEXT NOT NULL, '
        'retryAt INTEGER NOT NULL, misses INTEGER NOT NULL DEFAULT 1, '
        'PRIMARY KEY(profile, pair, chapter))');
    return db;
  }

  static String pairKey(String book, String source, String sourceId) =>
      '$book|$source|$sourceId';

  /// Chapters of this pair that must not be requested yet.
  Future<Set<String>> blocked(String profile, String pair) async {
    try {
      final rows = await (await _db()).query('unavailable_chapters',
        columns: ['chapter'], where: 'profile = ? AND pair = ? AND retryAt > ?',
        whereArgs: [profile, pair, _clock().millisecondsSinceEpoch]);
      return {for (final row in rows) row['chapter']! as String};
    } catch (_) {
      return const {}; // never block a scan on this optimisation
    }
  }

  /// Record a persistent miss; the pause doubles per miss up to [maxBackoff].
  Future<void> recordMiss(String profile, String pair, String chapter) async {
    try {
      final db = await _db();
      await db.transaction((t) async {
        final row = (await t.query('unavailable_chapters', columns: ['misses'],
          where: 'profile = ? AND pair = ? AND chapter = ?',
          whereArgs: [profile, pair, chapter])).firstOrNull;
        final misses = ((row?['misses'] as int?) ?? 0) + 1;
        var pause = firstBackoff * (1 << (misses - 1).clamp(0, 4));
        if (pause > maxBackoff) pause = maxBackoff;
        await t.insert('unavailable_chapters', {
          'profile': profile, 'pair': pair, 'chapter': chapter, 'misses': misses,
          'retryAt': _clock().add(pause).millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    } catch (_) {}
  }

  /// The chapter became readable (or was delivered): forget it.
  Future<void> clear(String profile, String pair, String chapter) async {
    try {
      await (await _db()).delete('unavailable_chapters',
        where: 'profile = ? AND pair = ? AND chapter = ?',
        whereArgs: [profile, pair, chapter]);
    } catch (_) {}
  }
}

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_store.dart';
import 'chapter_scan_queue.dart';
import 'package:sqflite/sqflite.dart';

/// Source-scoped check timing stays on the device and never touches the
/// cloud-synced library, read markers, or the active reading source.
class ChapterScanPolicy {
  // Only titles in the actual reading list are eligible for checks.
  static Duration intervalFor(String status) => status == 'reading'
      ? const Duration(minutes: 30) : Duration.zero;

  static String keyFor(SavedBook book, String sourceKey, String sourceId) =>
      jsonEncode([book.key, sourceKey, sourceId]);

  static bool isDue(String status, int? lastAttemptMs, DateTime now) {
    if (status != 'reading') return false;
    if (lastAttemptMs == null || lastAttemptMs <= 0) return true;
    final delta = now.millisecondsSinceEpoch - lastAttemptMs;
    // Wall-clock changes must not suppress checks indefinitely.
    return delta < 0 || delta >= intervalFor(status).inMilliseconds;
  }
}

class ChapterBackgroundScanSummary {
  const ChapterBackgroundScanSummary({
    required this.at,
    required this.checkedSources,
    required this.skippedSources,
    required this.foundChapters,
    this.updatedTitles = 0,
    required this.warnings,
    this.outcome = 'success',
    this.reason = '',
    this.origin = 'workmanager',
    this.nextEligibleAt,
    this.runId = 0, this.finishedAt, this.updatedAt, this.expiresAt,
    this.availableSources = 0, this.successfulSources = 0,
    this.failedSources = 0, this.skipReasons = const {}, this.chapterDecisions = const {},
    this.systemDelivery = 'disabled', this.postedNotifications = 0,
  });
  final DateTime at;
  final int checkedSources, skippedSources, foundChapters, warnings;
  final int updatedTitles;
  // Fixed codes only. Never persist exception messages, titles, URLs or tokens.
  final String outcome, reason, origin;
  final DateTime? nextEligibleAt, finishedAt, updatedAt, expiresAt;
  final int runId, availableSources, successfulSources, failedSources;
  final Map<String, int> skipReasons, chapterDecisions;
  final String systemDelivery;
  final int postedNotifications;
  Duration? get duration => finishedAt?.difference(at);


  String get resultText => switch (outcome) {
    'running' => 'Выполняется; завершение ещё не подтверждено',
    'interrupted' => 'Завершение не подтверждено; срок активности истёк',
    'skipped' => 'Отложена',
    'partial' => 'Завершена с ошибками источников',
    'error' => 'Ошибка',
    _ => 'Завершена',
  };
  String get reasonText => switch (reason) {
    'interrupted' => 'Процесс мог быть остановлен; очередь и найденные главы сохранены',
    'pages_unavailable' => 'Список страниц главы недоступен; глава остаётся для повтора',
    'chapter_metadata' => 'Метаданные глав не распознаны; проверка не считается успешной',
    'ready' => 'Ожидает обработки в очереди',
    'disabled' => 'Автоматический поиск выключен',
    'no_reading' => 'Нет доступных источников книг со статусом «Читаю»',
    'interval' => 'Интервал 30 минут ещё не истёк',
    'lease' => 'Источники заняты другой проверкой; после прерывания аренда истечёт',
    'cooldown' => 'Действует пауза источника после HTTP 403/429',
    'http_403' => 'Источник отказал в доступе (HTTP 403); автоматические запросы отложены',
    'http_429' => 'Источник ограничил частоту (HTTP 429); соблюдается Retry-After',
    'budget' => 'Время запуска исчерпано; оставшиеся источники сохранены в очереди',
    'profile_changed' => 'Профиль изменился; проверка остановлена',
    'source_error' => 'Источник или сеть недоступны; очередь сохранена для повтора',
    'timeout' => 'Истекло время ожидания источника; очередь сохранена',
    'scan_error' => 'Не удалось выполнить проверку; повтор при следующем запуске',
    'plugin_error' => 'Не удалось запустить плагины фоновой задачи',
    _ => '',
  };
}

/// Reloadable SharedPreferences reads fresh state from the background isolate.
class ChapterScanScheduleStore {
  ChapterScanScheduleStore({DateTime Function()? clock, Future<Database> Function()? database})
      : _clock = clock ?? DateTime.now,
        _database = database ?? (() => ChapterScanQueue().database());
  final DateTime Function() _clock;
  final Future<Database> Function() _database;
  // More than the 120s scan budget plus optional native delivery. A fresh
  // start is running, never evidence of a hung or killed Android process.
  static const activityLease = Duration(minutes: 3);
  static const _prefix = 'senreader.chapter_scan_schedule.v1';
  static const _lastPrefix = 'senreader.chapter_scan_last.v1';
  Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // Observe writes made by the WorkManager isolate.
    return prefs;
  }
  String _suffix(String profile) => profile.isEmpty ? '.guest' : '.user.$profile';

  Future<Map<String, int>> load(String profile) async {
    final raw = (await _prefs()).getString('$_prefix${_suffix(profile)}');
    if (raw == null || raw.length > 300000) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry(key.toString(),
          value is num ? value.toInt() : 0));
    } catch (_) {
      return {};
    }
  }

  Future<void> recordAttempts(String profile, Map<String, int> attempts) async {
    if (attempts.isEmpty) return;
    final latest = await load(profile);
    for (final entry in attempts.entries) {
      if ((latest[entry.key] ?? 0) < entry.value) {
        latest[entry.key] = entry.value;
      }
    }
    // Bound stale entries if the user replaces many bookmarked titles.
    if (latest.length > 3000) {
      final oldest = latest.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      latest
        ..clear()
        ..addEntries(oldest.take(3000));
    }
    await (await _prefs()).setString('$_prefix${_suffix(profile)}', jsonEncode(latest));
  }

  Map<String, Object?> _encode(ChapterBackgroundScanSummary value) => {
    'at': value.at.millisecondsSinceEpoch,
    'checked': value.checkedSources, 'skipped': value.skippedSources,
    'found': value.foundChapters, 'warnings': value.warnings,
    'updatedTitles': value.updatedTitles,
    'outcome': value.outcome, 'reason': value.reason, 'origin': value.origin,
    'next': value.nextEligibleAt?.millisecondsSinceEpoch,
    'finished': value.finishedAt?.millisecondsSinceEpoch,
    'available': value.availableSources, 'successful': value.successfulSources,
    'failed': value.failedSources, 'skipReasons': value.skipReasons,
    'chapters': value.chapterDecisions,
    'delivery': value.systemDelivery, 'posted': value.postedNotifications,
  };

  /// Every actual run gets a monotonic identity, including simultaneous
  /// periodic/one-off workers. Checkpoints update their own row only.
  Future<int> _insertRun(DatabaseExecutor t, String profile,
      ChapterBackgroundScanSummary value, int now) async {
    final id = await t.insert('scan_runs', {
      'profile': profile, 'origin': value.origin,
      'started': value.at.millisecondsSinceEpoch, 'updated': now,
      'expires': now + activityLease.inMilliseconds,
      'state': value.outcome, 'payload': jsonEncode(_encode(value)),
    });
    // Only new diagnostic history is bounded. Existing user data stays intact.
    await t.rawDelete('DELETE FROM scan_runs WHERE profile = ? AND origin = ? '
      'AND id NOT IN (SELECT id FROM scan_runs WHERE profile = ? AND origin = ? '
      'ORDER BY id DESC LIMIT 8)', [profile, value.origin, profile, value.origin]);
    return id;
  }

  Future<int> beginRun(String profile, ChapterBackgroundScanSummary value) async {
    final db = await _database();
    return db.transaction((t) => _insertRun(t, profile, value, _clock().millisecondsSinceEpoch));
  }

  Future<void> recordRun(String profile, ChapterBackgroundScanSummary value) async {
    final db = await _database();
    final now = _clock().millisecondsSinceEpoch;
    if (value.runId == 0) {
      // Compatibility for bootstrap/legacy callers without a run identity.
      // Never let an old timestamp overwrite a newer attempt of that origin.
      await db.transaction((t) async {
        final latest = await t.query('scan_runs', where: 'profile = ? AND origin = ?',
          whereArgs: [profile, value.origin], orderBy: 'id DESC', limit: 1);
        if (latest.isNotEmpty && (latest.single['started'] as int) > value.at.millisecondsSinceEpoch) return;
        await _insertRun(t, profile, value, now);
      });
      return;
    }
    await db.update('scan_runs', {
      'updated': now, 'expires': now + activityLease.inMilliseconds,
      'state': value.outcome, 'payload': jsonEncode(_encode(value)),
    }, where: 'id = ? AND profile = ? AND origin = ? AND '
      '((state = ? AND expires > ?) OR (state = ? AND state != ?))',
      whereArgs: [value.runId, profile, value.origin, 'running', now, value.outcome, 'running']);
  }

  Future<void> recordBootstrapFailure(String profile,
      ChapterBackgroundScanSummary value) async {
    try { await recordRun(profile, value); }
    catch (_) {
      await (await _prefs()).setString('$_lastPrefix.bootstrap.${value.origin}${_suffix(profile)}',
        jsonEncode(_encode(value)));
    }
  }

  Future<ChapterBackgroundScanSummary?> lastRun(String profile,
      {bool workmanagerOnly = false, bool appOnly = false}) async {
    final origin = workmanagerOnly ? 'workmanager' : appOnly ? 'app' : null;
    ChapterBackgroundScanSummary? latest;
    try {
      final db = await _database();
      final rows = await db.query('scan_runs',
        where: 'profile = ?${origin == null ? '' : ' AND origin = ?'}',
        whereArgs: [profile, if (origin != null) origin], orderBy: 'id DESC', limit: 1);
      if (rows.isNotEmpty) latest = _decode(rows.single['payload'] as String, row: rows.single);
    } catch (_) { /* SQLite bootstrap failure may still have a preferences record. */ }
    final prefs = await _prefs();
    for (final candidate in origin == null ? ['app', 'workmanager'] : [origin]) {
      final bootstrap = prefs.getString('$_lastPrefix.bootstrap.$candidate${_suffix(profile)}');
      final failure = bootstrap == null ? null : _decode(bootstrap);
      if (failure != null && (latest == null || failure.at.isAfter(latest.at))) latest = failure;
    }
    if (latest != null) return latest;
    // Preserve v1 summaries in place. They never recorded a confirmed end.
    var raw = prefs.getString('$_lastPrefix${workmanagerOnly ? '.workmanager' : ''}${_suffix(profile)}');
    if (raw == null && workmanagerOnly) raw = prefs.getString('$_lastPrefix${_suffix(profile)}');
    final legacy = raw == null ? null : _decode(raw);
    return origin == null || legacy?.origin == origin ? legacy : null;
  }

  ChapterBackgroundScanSummary? _decode(String raw, {Map<String, Object?>? row}) {
    try {
      final record = jsonDecode(raw);
      if (record is! Map) return null;
      final timestamp = (record['at'] as num?)?.toInt() ?? 0;
      if (timestamp <= 0) return null;
      DateTime? date(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
      var outcome = record['outcome'] as String? ??
          (((record['warnings'] as num?) ?? 0) > 0 ? 'partial' : 'success');
      final expires = date(row?['expires']) ??
          DateTime.fromMillisecondsSinceEpoch(timestamp).add(activityLease);
      if (outcome == 'running' && !expires.isAfter(_clock())) outcome = 'interrupted';
      return ChapterBackgroundScanSummary(
        runId: (row?['id'] as int?) ?? 0,
        at: DateTime.fromMillisecondsSinceEpoch(timestamp),
        updatedAt: date(row?['updated']), expiresAt: expires,
        finishedAt: date(record['finished']),
        checkedSources: (record['checked'] as num?)?.toInt() ?? 0,
        skippedSources: (record['skipped'] as num?)?.toInt() ?? 0,
        foundChapters: (record['found'] as num?)?.toInt() ?? 0,
        updatedTitles: (record['updatedTitles'] as num?)?.toInt() ?? 0,
        warnings: (record['warnings'] as num?)?.toInt() ?? 0,
        availableSources: (record['available'] as num?)?.toInt() ?? 0,
        successfulSources: (record['successful'] as num?)?.toInt() ?? 0,
        failedSources: (record['failed'] as num?)?.toInt() ?? 0,
        skipReasons: record['skipReasons'] is Map ? Map<String, int>.from(record['skipReasons']) : const {},
        chapterDecisions: record['chapters'] is Map ? Map<String, int>.from(record['chapters']) : const {},
        systemDelivery: record['delivery'] as String? ?? 'unknown',
        postedNotifications: (record['posted'] as num?)?.toInt() ?? 0,
        outcome: outcome,
        reason: outcome == 'interrupted' ? 'interrupted' : record['reason'] as String? ?? '',
        origin: record['origin'] as String? ?? 'workmanager',
        nextEligibleAt: date(record['next']),
      );
    } catch (_) { return null; }
  }

  Future<void> recordRegistration(String profile, {required bool success}) async {
    await (await _prefs()).setString('$_lastPrefix.registration${_suffix(profile)}',
      jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'success': success}));
  }

  Future<bool?> registrationSucceeded(String profile) async {
    final raw = (await _prefs()).getString('$_lastPrefix.registration${_suffix(profile)}');
    if (raw == null) return null;
    try { return (jsonDecode(raw) as Map)['success'] as bool?; }
    catch (_) { return null; }
  }
}


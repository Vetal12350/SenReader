import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_store.dart';

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
    required this.warnings,
    this.outcome = 'success',
    this.reason = '',
    this.origin = 'workmanager',
    this.nextEligibleAt,
  });
  final DateTime at;
  final int checkedSources, skippedSources, foundChapters, warnings;
  // Fixed codes only. Never persist exception messages, titles, URLs or tokens.
  final String outcome, reason, origin;
  final DateTime? nextEligibleAt;

  String get resultText => switch (outcome) {
    'running' => 'Начата; завершение не подтверждено',
    'skipped' => 'Отложена',
    'partial' => 'Завершена с ошибками источников',
    'error' => 'Ошибка',
    _ => 'Завершена',
  };
  String get reasonText => switch (reason) {
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

  Future<void> recordRun(String profile, ChapterBackgroundScanSummary value) async {
    final raw = jsonEncode({
      'at': value.at.millisecondsSinceEpoch,
      'checked': value.checkedSources,
      'skipped': value.skippedSources,
      'found': value.foundChapters,
      'warnings': value.warnings,
      'outcome': value.outcome,
      'reason': value.reason,
      'origin': value.origin,
      'next': value.nextEligibleAt?.millisecondsSinceEpoch,
    });
    final prefs = await _prefs();
    await prefs.setString('$_lastPrefix${_suffix(profile)}', raw);
    // Opening the app must not erase evidence that Android never ran a worker.
    if (value.origin == 'workmanager') {
      await prefs.setString('$_lastPrefix.workmanager${_suffix(profile)}', raw);
    }
  }

  Future<ChapterBackgroundScanSummary?> lastRun(String profile,
      {bool workmanagerOnly = false}) async {
    final prefs = await _prefs();
    var raw = prefs.getString('$_lastPrefix${workmanagerOnly ? '.workmanager' : ''}${_suffix(profile)}');
    // An old summary was written only by a worker. Keep that evidence visible.
    if (raw == null && workmanagerOnly) {
      final legacy = await lastRun(profile);
      return legacy?.origin == 'workmanager' ? legacy : null;
    }
    if (raw == null) return null;
    try {
      final record = jsonDecode(raw);
      if (record is! Map) return null;
      final timestamp = (record['at'] as num?)?.toInt() ?? 0;
      if (timestamp <= 0) return null;
      return ChapterBackgroundScanSummary(
        at: DateTime.fromMillisecondsSinceEpoch(timestamp),
        checkedSources: (record['checked'] as num?)?.toInt() ?? 0,
        skippedSources: (record['skipped'] as num?)?.toInt() ?? 0,
        foundChapters: (record['found'] as num?)?.toInt() ?? 0,
        warnings: (record['warnings'] as num?)?.toInt() ?? 0,
        outcome: record['outcome'] as String? ??
            (((record['warnings'] as num?) ?? 0) > 0 ? 'partial' : 'success'),
        reason: record['reason'] as String? ?? '',
        origin: record['origin'] as String? ?? 'workmanager',
        nextEligibleAt: record['next'] is num ? DateTime.fromMillisecondsSinceEpoch(
            (record['next'] as num).toInt()) : null,
      );
    } catch (_) {
      return null;
    }
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


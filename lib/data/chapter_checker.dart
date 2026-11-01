import '../core/chapter_identity.dart';
import '../core/models.dart';
import '../core/title_matching.dart';
import 'catalog_repository.dart';
import 'chapter_inbox_store.dart';
import 'chapter_scan_schedule.dart';
import 'library_store.dart';

class ChapterDiscovery {
  const ChapterDiscovery({
    required this.book, required this.sourceKey,
    required this.chapter, required this.canonicalKey,
  });
  final UnifiedManga book;
  final String sourceKey;
  final Chapter chapter;
  final String canonicalKey;
}

class ChapterScanReport {
  const ChapterScanReport(this.discoveries, this.warnings, this.checkedTitles,
      {this.diagnostics = const [], this.checkedSources = 0,
       this.skippedSources = 0});
  final List<ChapterDiscovery> discoveries;
  final List<String> warnings;
  final int checkedTitles;
  final List<String> diagnostics;
  final int checkedSources, skippedSources;
}

/// Checks each precisely title-linked source without moving the reader's
/// chosen source or progress. The first source scan establishes its baseline.
/// Canonical chapter keys deduplicate releases across linked sources.
class ChapterChecker {
  ChapterChecker({required this.repository, required this.library});
  final CatalogRepository repository;
  final LibraryStore library;
  static const maxNewCandidatesPerSource = 12;
  static const maxBackgroundSourcesPerRun = 12;

  static bool _trustedLink(SavedBook saved, String source) {
    final entry = saved.entries[source];
    return entry != null && (source == saved.preferredSource ||
        normalizedTitle(entry.title) == normalizedTitle(saved.title));
  }

  static bool _alreadyRead(SavedBook saved, String key) {
    // Cross-source suppression never writes reading markers into another
    // provider's history; only two precisely title-matched providers qualify.
    return saved.readChapterKeys.any((value) {
      final bar = value.indexOf('|');
      if (bar <= 0 || value.substring(bar + 1) != key) return false;
      final source = value.substring(0, bar);
      return (source == 'senkuro' || source == 'readmanga') &&
          _trustedLink(saved, source);
    });
  }

  /// Manual scans are always exhaustive; only background scans are scheduled.
  Future<ChapterScanReport> check({bool diagnostics = false,
      bool smartSchedule = false}) async {
    final discoveries = <ChapterDiscovery>[];
    final warnings = <String>[];
    final scanDetails = <String>[];
    final now = DateTime.now();
    final scanProfile = library.profileId;
    final schedule = ChapterScanScheduleStore();
    final lastAttempts = smartSchedule
        ? await schedule.load(scanProfile) : <String, int>{};
    final attempts = <String, int>{};
    var checkedSources = 0;
    var skippedSources = 0;
    final originalSource = <String, String>{};
    // Archived and active inbox entries are both proof of earlier delivery.
    final delivered = <String>{};
    for (final entry in await ChapterInboxStore().load()) {
      final canonical = canonicalChapterKey(
          Chapter(id: entry.chapterId, name: entry.chapterName));
      if (canonical != null) delivered.add('${entry.bookKey}|$canonical');
    }
    var checked = 0;
    final savedBooks = List<SavedBook>.of(library.items);
    if (smartSchedule) {
      int priority(SavedBook book) => switch (book.status) {
        'reading' => 0,
        'planned' => 1,
        'completed' => 2,
        _ => 3,
      };
      savedBooks.sort((a, b) => priority(a).compareTo(priority(b)));
    }
    for (final saved in savedBooks) {
      if (saved.status == 'viewed' || saved.status == 'dropped') continue;
      checked++;
      originalSource[saved.key] = saved.preferredSource;
      final book = saved.toUnified();
      final keys = [
        saved.preferredSource,
        ...saved.entries.keys.where((k) => k != saved.preferredSource),
      ];
      for (final sourceKey in keys) {
        final source = repository.sources[sourceKey];
        final entry = book.entries[sourceKey];
        if (source == null || entry == null || !_trustedLink(saved, sourceKey)) {
          if (diagnostics && sourceKey == saved.preferredSource) {
            scanDetails.add('${saved.title}: основной источник не найден');
          }
          continue;
        }
        final scanKey = ChapterScanPolicy.keyFor(saved, sourceKey, entry.id);
        if (smartSchedule &&
            (!ChapterScanPolicy.isDue(saved.status, lastAttempts[scanKey], now) ||
             checkedSources >= maxBackgroundSourcesPerRun)) {
          skippedSources++;
          continue;
        }
        // A manual full refresh also postpones the next redundant
        // background scan of the same source.
        attempts[scanKey] = now.millisecondsSinceEpoch;
        checkedSources++;
        try {
          final detail = smartSchedule
              ? await source.detail(entry).timeout(const Duration(seconds: 18))
              : await source.detail(entry);
          await library.load();
          var current = library.get(book);
          if (current == null ||
              current.preferredSource != originalSource[saved.key] ||
              current.entries[sourceKey]?.id != entry.id) continue;
          final chapters = <String, Chapter>{};
          for (final chapter in detail.chapters) {
            final key = canonicalChapterKey(chapter);
            if (key != null) chapters.putIfAbsent(key, () => chapter);
          }
          final dates = <String, DateTime>{};
          for (final e in chapters.entries) {
            final date = e.value.publishedAt;
            if (date != null) dates[e.key] = date;
          }
          if (diagnostics && sourceKey == current.preferredSource) {
            final newest = chapters.values.toList()
              ..sort((a, b) => compareChapterChronology(b, a) ?? 0);
            final chapter = newest.firstOrNull;
            if (chapter == null) {
              scanDetails.add('${saved.title} · ${source.name}: '
                  'главы не распознаны');
            } else {
              final canonical = canonicalChapterKey(chapter)!;
              final date = chapter.publishedAt;
              final published = date == null ? 'дата неизвестна' :
                  '${date.day.toString().padLeft(2, '0')}.'
                  '${date.month.toString().padLeft(2, '0')}.'
                  '${date.year}';
              final seen = current.seenChapterKeys.contains(canonical);
              final read = library.isChapterRead(book, chapter, sourceKey);
              final alerted = delivered.contains('${current.key}|$canonical');
              scanDetails.add('${saved.title} · ${source.name}: '
                  '${chapter.name} ($published), '
                  'известна: ${seen ? 'да' : 'нет'}, '
                  'прочитана: ${read ? 'да' : 'нет'}, '
                  'уведомление было: ${alerted ? 'да' : 'нет'}');
            }
          }
          if (!current.initializedSources.contains(sourceKey)) {
            // The initial scan normally establishes a silent baseline. But
            // for an actively read title, a recently published chapter newer
            // than the last completed chapter is a real update even if the
            // first scan happens after its publication.
            final readChapters = chapters.values.where(
                (chapter) => library.isChapterRead(book, chapter, sourceKey) &&
                    canonicalChapterKey(chapter) != null).toList()
              ..sort((a, b) => compareChapterChronology(b, a) ?? 0);
            final lastRead = readChapters.firstOrNull;
            final recent = <String, Chapter>{};
            final unverifiedRecent = <String>{};
            if (sourceKey == current.preferredSource &&
                current.status == 'reading' && lastRead != null) {
              final now = DateTime.now().toUtc();
              final candidates = chapters.entries.where((item) {
                final posted = item.value.publishedAt?.toUtc();
                if (posted == null || current!.seenChapterKeys.contains(item.key) ||
                    _alreadyRead(current, item.key)) return false;
                final age = now.difference(posted);
                return !age.isNegative && age <= const Duration(hours: 36) &&
                    (compareChapterChronology(item.value, lastRead) ?? 0) > 0;
              }).toList()
                ..sort((a, b) =>
                    compareChapterChronology(b.value, a.value) ?? 0);
              for (final candidate in candidates.take(2)) {
                try {
                  final pages = await source.pages(candidate.value);
                  if (pages.any((p) {
                    final uri = Uri.tryParse(p.url);
                    return uri != null && uri.scheme == 'https' &&
                        uri.host.isNotEmpty;
                  })) {
                    recent[candidate.key] = candidate.value;
                  } else {
                    unverifiedRecent.add(candidate.key);
                  }
                } catch (_) {
                  // Keep this recent chapter unseen so a later scan retries.
                  unverifiedRecent.add(candidate.key);
                }
              }
            }
            await library.load();
            current = library.get(book);
            if (current == null ||
                current.preferredSource != originalSource[saved.key] ||
                current.entries[sourceKey]?.id != entry.id) continue;
            await library.recordChapterScan(current.key, sourceKey,
                chapters.keys.where((key) => !unverifiedRecent.contains(key)),
                sourceDates: dates);
            discoveries.addAll([
              for (final chapter in recent.entries)
                ChapterDiscovery(book: book, sourceKey: sourceKey,
                    chapter: chapter.value, canonicalKey: chapter.key),
            ]);
            continue;
          }
          // Recover just-published, unread chapters swallowed by earlier
          // versions' silent first scan. A recovery must not replay any
          // chapter already shown in the inbox (including archived entries).
          final recovered = <String, Chapter>{};
          if (sourceKey == current.preferredSource &&
              current.status == 'reading') {
            final read = chapters.values.where((ch) =>
                canonicalChapterKey(ch) != null &&
                library.isChapterRead(book, ch, sourceKey)).toList()
              ..sort((a, b) => compareChapterChronology(b, a) ?? 0);
            final lastRead = read.firstOrNull;
            if (lastRead != null) {
              final now = DateTime.now().toUtc();
              final missed = chapters.entries.where((item) {
                final time = item.value.publishedAt?.toUtc();
                if (time == null || !current!.seenChapterKeys.contains(item.key) ||
                    delivered.contains('${current.key}|${item.key}') ||
                    _alreadyRead(current, item.key)) return false;
                final age = now.difference(time);
                return !age.isNegative && age <= const Duration(hours: 36) &&
                    (compareChapterChronology(item.value, lastRead) ?? 0) > 0;
              }).toList()
                ..sort((a, b) =>
                    compareChapterChronology(b.value, a.value) ?? 0);
              for (final item in missed.take(2)) {
                try {
                  final pages = await source.pages(item.value)
                      .timeout(const Duration(seconds: 12));
                  if (pages.any((p) {
                    final uri = Uri.tryParse(p.url);
                    return uri != null && uri.scheme == 'https' &&
                        uri.host.isNotEmpty;
                  })) recovered[item.key] = item.value;
                } catch (_) {
                  warnings.add(saved.title + ': проверка главы отложена');
                }
              }
            }
          }
          final verified = <String, Chapter>{};
          var attempts = 0;
          for (final chapter in chapters.entries) {
            current = library.get(book);
            if (current == null) break;
            if (current.seenChapterKeys.contains(chapter.key) ||
                _alreadyRead(current, chapter.key)) continue;
            if (attempts >= maxNewCandidatesPerSource) {
              warnings.add(saved.title + ': проверка остальных глав отложена');
              break;
            }
            attempts++;
            try {
              final pages = await source.pages(chapter.value);
              if (!pages.any((p) {
                final uri = Uri.tryParse(p.url);
                return uri != null && uri.scheme == 'https' &&
                    uri.host.isNotEmpty;
              })) continue;
              verified[chapter.key] = chapter.value;
            } catch (_) {
              warnings.add(saved.title + ': глава временно недоступна');
            }
          }
          if (verified.isEmpty && recovered.isEmpty) continue;
          await library.load();
          current = library.get(book);
          if (current == null ||
              current.preferredSource != originalSource[saved.key] ||
              current.entries[sourceKey]?.id != entry.id) continue;
          final newKeys = verified.keys.where((key) =>
              !current!.seenChapterKeys.contains(key) &&
              !_alreadyRead(current, key)).toSet();
          if (newKeys.isEmpty && recovered.isEmpty) continue;
          // Durable dedup is saved before any notification is exposed.
          if (newKeys.isNotEmpty) {
            await library.recordChapterScan(current.key, sourceKey,
                newKeys, sourceDates: dates);
          }
          discoveries.addAll([
            for (final key in newKeys)
              ChapterDiscovery(book: book, sourceKey: sourceKey,
                  chapter: verified[key]!, canonicalKey: key),
            for (final chapter in recovered.entries)
              ChapterDiscovery(book: book, sourceKey: sourceKey,
                  chapter: chapter.value, canonicalKey: chapter.key),
          ]);
          delivered.addAll([...newKeys, ...recovered.keys]
              .map((key) => '${current!.key}|$key'));
        } catch (_) {
          warnings.add(saved.title + ': один из источников недоступен');
          if (diagnostics && sourceKey == saved.preferredSource) {
            scanDetails.add('${saved.title} · ${source.name}: '
                'не удалось загрузить главы');
          }
        }
      }
    }
    await library.load();
    if (library.profileId == scanProfile) {
      await schedule.recordAttempts(scanProfile, attempts);
    }
    discoveries.removeWhere((d) =>
        library.get(d.book)?.preferredSource !=
            originalSource[normalizedTitle(d.book.title)]);
    return ChapterScanReport(discoveries, warnings, checked,
        diagnostics: scanDetails, checkedSources: checkedSources,
        skippedSources: skippedSources);
  }
}

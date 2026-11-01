import '../core/chapter_identity.dart';
import '../core/models.dart';
import '../core/title_matching.dart';
import 'catalog_repository.dart';
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
  const ChapterScanReport(this.discoveries, this.warnings, this.checkedTitles);
  final List<ChapterDiscovery> discoveries;
  final List<String> warnings;
  final int checkedTitles;
}

/// Checks each precisely title-linked source without moving the reader's
/// chosen source or progress. The first source scan establishes its baseline.
/// Canonical chapter keys deduplicate releases across linked sources.
class ChapterChecker {
  ChapterChecker({required this.repository, required this.library});
  final CatalogRepository repository;
  final LibraryStore library;
  static const maxNewCandidatesPerSource = 12;

  static bool _trustedLink(SavedBook saved, String source) {
    final entry = saved.entries[source];
    return entry != null &&
        normalizedTitle(entry.title) == normalizedTitle(saved.title);
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

  Future<ChapterScanReport> check() async {
    final discoveries = <ChapterDiscovery>[];
    final warnings = <String>[];
    final originalSource = <String, String>{};
    var checked = 0;
    for (final saved in List<SavedBook>.of(library.items)) {
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
          continue;
        }
        try {
          final detail = await source.detail(entry);
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
          if (!current.initializedSources.contains(sourceKey)) {
            await library.recordChapterScan(current.key, sourceKey,
                chapters.keys, sourceDates: dates);
            continue;
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
          if (verified.isEmpty) continue;
          await library.load();
          current = library.get(book);
          if (current == null ||
              current.preferredSource != originalSource[saved.key] ||
              current.entries[sourceKey]?.id != entry.id) continue;
          final newKeys = verified.keys.where((key) =>
              !current!.seenChapterKeys.contains(key) &&
              !_alreadyRead(current, key)).toSet();
          if (newKeys.isEmpty) continue;
          // Durable dedup is saved before any notification is exposed.
          await library.recordChapterScan(current.key, sourceKey,
              newKeys, sourceDates: dates);
          discoveries.addAll([
            for (final key in newKeys)
              ChapterDiscovery(book: book, sourceKey: sourceKey,
                  chapter: verified[key]!, canonicalKey: key),
          ]);
        } catch (_) {
          warnings.add(saved.title + ': один из источников недоступен');
        }
      }
    }
    await library.load();
    discoveries.removeWhere((d) =>
        library.get(d.book)?.preferredSource !=
            originalSource[normalizedTitle(d.book.title)]);
    return ChapterScanReport(discoveries, warnings, checked);
  }
}

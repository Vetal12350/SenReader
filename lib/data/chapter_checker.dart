import '../core/chapter_identity.dart';
import '../core/models.dart';
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

/// Checks only each saved book's explicitly selected source. The first
/// successful scan of a newly selected source establishes a silent baseline.
/// Public page availability is verified before reporting a new chapter.
class ChapterChecker {
  ChapterChecker({required this.repository, required this.library});
  final CatalogRepository repository;
  final LibraryStore library;
  static const maxNewCandidatesPerSource = 12;

  Future<ChapterScanReport> check() async {
    final discoveries = <ChapterDiscovery>[];
    final warnings = <String>[];
    var checked = 0;
    for (final saved in List<SavedBook>.of(library.items)) {
      checked++;
      final book = saved.toUnified();
      final selected = saved.preferredSource;
      final source = repository.sources[selected];
      final entry = book.entries[selected];
      if (source == null || entry == null) {
        warnings.add(saved.title + ': выбранный источник недоступен');
        continue;
      }
      try {
        final detail = await source.detail(entry);
        await library.load();
        final current = library.get(book);
        if (current == null || current.preferredSource != selected) continue;
        final chapters = <String, Chapter>{};
        for (final chapter in detail.chapters) {
          final key = canonicalChapterKey(chapter);
          if (key != null) chapters.putIfAbsent(key, () => chapter);
        }
        if (!current.initializedSources.contains(selected)) {
          // On first successful visit baseline ALL existing public chapters.
          // Do not alert historical chapters or resurrect an old scan.
          await library.recordChapterScan(current.key, selected, chapters.keys);
          continue;
        }
        final newlyVerified = <String>[];
        var attempts = 0;
        for (final chapterEntry in chapters.entries) {
          if (current.seenChapterKeys.contains(chapterEntry.key)) continue;
          if (attempts >= maxNewCandidatesPerSource) {
            warnings.add(saved.title + ': проверка остальных глав отложена');
            break;
          }
          attempts++;
          try {
            final images = await source.pages(chapterEntry.value);
            if (images.isEmpty) continue;
            // Check syntactic HTTPS URLs; no paid/protected content bypass.
            if (!images.any((p) {
              final uri = Uri.tryParse(p.url);
              return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
            })) continue;
            newlyVerified.add(chapterEntry.key);
            discoveries.add(ChapterDiscovery(
              book: book, sourceKey: selected,
              chapter: chapterEntry.value, canonicalKey: chapterEntry.key,
            ));
          } catch (_) {
            warnings.add(saved.title + ': ' + source.name +
                ' — новая глава пока недоступна для чтения');
          }
        }
        // Durable dedup is committed before exposing discoveries to the UI.
        if (newlyVerified.isNotEmpty) {
          await library.recordChapterScan(
            current.key, selected, newlyVerified);
        }
      } catch (_) {
        warnings.add(saved.title + ': ' + source.name + ' недоступен');
      }
    }
    // A foreground selection made during a request invalidates that result.
    await library.load();
    discoveries.removeWhere((item) =>
        library.get(item.book)?.preferredSource != item.sourceKey);
    return ChapterScanReport(discoveries, warnings, checked);
  }
}

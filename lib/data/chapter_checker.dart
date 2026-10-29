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

class _SourceResult {
  _SourceResult(this.source, this.chapters);
  final String source;
  final List<Chapter> chapters;
}

/// Manual, bounded, source-independent chapter detection.
///
/// First successful scan per source initializes a baseline and produces NO
/// releases. The source whose detail call finishes first is inspected first;
/// no provider is given an artificial preference when selecting a release.
/// Each candidate is verified with its public page-list endpoint before an
/// alert can be returned. Network failures leave the baseline intact.
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
      UnifiedManga book = saved.toUnified();
      try {
        // Exact normalized title matching only; never fuzzy-link unrelated
        // translations. A failed lookup does not block known sources.
        final linked = await repository.findOtherSources(book);
        if (linked.entries.length > book.entries.length) {
          await library.add(linked);
          book = linked;
        }
      } catch (_) {
        warnings.add(saved.title + ': поиск альтернативных источников недоступен');
      }
      final current = library.get(book);
      if (current == null) continue;
      final completed = <_SourceResult>[];
      await Future.wait(book.entries.entries.map((record) async {
        final source = repository.sources[record.key];
        if (source == null) return;
        try {
          final detail = await source.detail(record.value);
          completed.add(_SourceResult(record.key, detail.chapters));
        } catch (_) {
          warnings.add(saved.title + ': ' + source.name + ' недоступен');
        }
      }));

      for (final response in completed) {
        final source = repository.sources[response.source];
        if (source == null) continue;
        final chapters = <String, Chapter>{};
        for (final chapter in response.chapters) {
          final key = canonicalChapterKey(chapter);
          if (key != null) chapters.putIfAbsent(key, () => chapter);
        }
        if (!current.initializedSources.contains(response.source)) {
          // On first successful visit baseline ALL existing public chapters.
          // Do not alert historical chapters or resurrect an old scan.
          await library.recordChapterScan(current.key, response.source, chapters.keys);
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
              book: book, sourceKey: response.source,
              chapter: chapterEntry.value, canonicalKey: chapterEntry.key,
            ));
          } catch (_) {
            warnings.add(saved.title + ': ' + source.name +
                ' — новая глава пока недоступна для чтения');
          }
        }
        // Durable dedup is committed before exposing discoveries to the UI.
        // A later source will see these keys and cannot alert them again.
        if (newlyVerified.isNotEmpty) {
          await library.recordChapterScan(
            current.key, response.source, newlyVerified);
        }
      }
    }
    return ChapterScanReport(discoveries, warnings, checked);
  }
}

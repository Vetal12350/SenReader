import '../core/models.dart';
import '../core/source.dart';
import '../core/title_matching.dart';
import '../core/chapter_identity.dart';
import 'readmanga_source.dart';
import 'senkuro_source.dart';

class CatalogRepository {
  CatalogRepository({Map<String, MangaSource>? sources}) : sources = sources ?? {
    'senkuro': SenkuroSource(),
    'readmanga': ReadMangaSource(),
  };
  final Map<String, MangaSource> sources;

  Future<CatalogResult> getCatalog({String query = '', String? sourceKey}) async {
    final warnings = <String>[];
    final orderedSources = sourceKey == null
        ? sources.values.toList()
        : [if (sources[sourceKey] != null) sources[sourceKey]!];
    final futures = orderedSources.map((source) async {
      try {
        return query.trim().isEmpty
          ? await source.popular()
          : await source.search(query.trim());
      } catch (e) {
        warnings.add('${source.name}: $e');
        return <MangaEntry>[];
      }
    });
    final lists = await Future.wait(futures);
    final senkuroIndex = orderedSources.indexWhere((source) => source.key == 'senkuro');
    return CatalogResult(
      books: mergeEntries(lists.expand((e) => e)),
      warnings: warnings,
      senkuroPopular: query.trim().isEmpty && senkuroIndex >= 0
          ? lists[senkuroIndex] : const [],
    );
  }

  /// Prefer the greatest *numbered* chapter, never the number of HTML rows.
  /// Only a verified public HTTPS page list can make a different source win.
  /// On timeouts or ambiguous numbering retain the current source.
  Future<String> mostCompleteSource(UnifiedManga book, String current,
      {int? currentChapterCount}) async {
    if (!book.entries.containsKey(current) || book.entries.length < 2) {
      return current;
    }
    final latest = await Future.wait(book.entries.entries.map((entry) async {
      final source = sources[entry.key];
      if (source == null) return (entry.key, null as Chapter?);
      try {
        final chapters = (await source.detail(entry.value)
            .timeout(const Duration(seconds: 12))).chapters;
        Chapter? newest;
        for (final chapter in chapters) {
          if (canonicalChapterKey(chapter) == null) continue;
          if (newest == null ||
              (compareChapterChronology(chapter, newest) ?? 0) > 0) {
            newest = chapter;
          }
        }
        return (entry.key, newest);
      } catch (_) {
        return (entry.key, null as Chapter?);
      }
    }));
    final currentLatest = latest.where((e) => e.$1 == current).firstOrNull?.$2;
    if (currentLatest == null) return current;
    final newer = latest.where((e) =>
        e.$1 != current && e.$2 != null &&
        (compareChapterChronology(e.$2!, currentLatest) ?? 0) > 0).toList()
      ..sort((a, b) => compareChapterChronology(b.$2!, a.$2!) ?? 0);
    for (final candidate in newer) {
      final source = sources[candidate.$1];
      if (source == null) continue;
      try {
        final pages = await source.pages(candidate.$2!)
            .timeout(const Duration(seconds: 12));
        if (pages.any((image) {
          final uri = Uri.tryParse(image.url);
          return uri != null && uri.scheme == 'https' &&
              uri.host.isNotEmpty;
        })) return candidate.$1;
      } catch (_) {
        // An inaccessible new chapter must not replace a readable version.
      }
    }
    return current;
  }

  // A matching title can come from multiple sites, but never assume localization
  // equivalence when labels differ. Later versions will add user-approved links.
  Future<UnifiedManga> findOtherSources(UnifiedManga book) async {
    final entries = {...book.entries};
    final titleKey = normalizedTitle(book.title);
    final missing = sources.values
        .where((source) => !entries.containsKey(source.key)).toList();
    if (missing.isEmpty) return book;

    // Unrelated providers used to block one another: two 8-second source
    // failures could delay opening a title by 16 seconds. Execute discovery
    // concurrently, but apply results in stable source order.
    final candidates = await Future.wait(missing.map((source) async {
      try {
        final matches = await source.search(book.title)
            .timeout(const Duration(seconds: 8));
        for (final match in matches) {
          if (normalizedTitle(match.title) == titleKey) {
            return (source.key, match);
          }
        }
      } catch (_) {
        // Missing or blocked providers must not affect existing sources.
      }
      return null;
    }));
    for (final result in candidates) {
      if (result != null) entries[result.$1] = result.$2;
    }
    return UnifiedManga(title: book.title, entries: entries);
  }
}

import '../core/models.dart';
import '../core/source.dart';
import '../core/title_matching.dart';
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

  /// Choose only among verified chapter lists; never overwrite a user's
  /// explicitly saved preferred source. A tie keeps the current source.
  Future<String> mostCompleteSource(UnifiedManga book, String current,
      {int? currentChapterCount}) async {
    if (book.entries.length < 2) return current;
    final counts = await Future.wait(book.entries.entries.map((entry) async {
      if (entry.key == current && currentChapterCount != null) {
        return (entry.key, currentChapterCount);
      }
      final source = sources[entry.key];
      if (source == null) return (entry.key, -1);
      try {
        final detail = await source.detail(entry.value)
          .timeout(const Duration(seconds: 12));
        return (entry.key, detail.chapters.length);
      } catch (_) {
        return (entry.key, -1);
      }
    }));
    final currentCount = counts.where((item) => item.$1 == current)
      .map((item) => item.$2).firstOrNull ?? -1;
    var winner = current;
    var maxCount = currentCount;
    for (final item in counts) {
      if (item.$2 > maxCount && item.$2 > 0) {
        maxCount = item.$2;
        winner = item.$1;
      }
    }
    return winner;
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

import '../core/models.dart';
import '../core/source.dart';
import '../core/title_matching.dart';
import 'readmanga_source.dart';
import 'senkuro_source.dart';
import 'remanga_source.dart';

class CatalogRepository {
  CatalogRepository({Map<String, MangaSource>? sources}) : sources = sources ?? {
    'senkuro': SenkuroSource(),
    'readmanga': ReadMangaSource(),
    'remanga': ReMangaSource(),
  };
  final Map<String, MangaSource> sources;

  Future<CatalogResult> getCatalog({String query = ''}) async {
    final warnings = <String>[];
    final futures = sources.values.map((source) async {
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
    return CatalogResult(books: mergeEntries(lists.expand((e) => e)), warnings: warnings);
  }

  // Only one exact match per provider is safe to connect automatically.
  Future<UnifiedManga> findOtherSources(UnifiedManga book) async {
    if (book.requiresLinkApproval) return book;
    final entries = {...book.entries};
    for (final source in sources.values) {
      if (entries.containsKey(source.key)) continue;
      try {
        final matches = await source.search(book.title);
        final exact = {for (final match in matches)
          if (normalizedTitle(match.title) == normalizedTitle(book.title)) match.id: match};
        if (exact.length == 1) entries[source.key] = exact.values.single;
      } catch (_) {
        // Keep existing source even if another site is temporarily unavailable.
      }
    }
    return UnifiedManga(title: book.title, entries: entries, savedId: book.savedId,
      requiresLinkApproval: book.requiresLinkApproval);
  }
}

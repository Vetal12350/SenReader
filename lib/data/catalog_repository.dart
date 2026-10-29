import '../core/models.dart';
import '../core/source.dart';
import '../core/title_matching.dart';
import 'readmanga_source.dart';
import 'senkuro_source.dart';

class CatalogRepository {
  CatalogRepository() : sources = {
    'senkuro': SenkuroSource(),
    'readmanga': ReadMangaSource(),
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

  // A matching title can come from both sites, but never assume localization
  // equivalence when labels differ. Later versions will add user-approved links.
  Future<UnifiedManga> findOtherSources(UnifiedManga book) async {
    final entries = {...book.entries};
    for (final source in sources.values) {
      if (entries.containsKey(source.key)) continue;
      try {
        final matches = await source.search(book.title);
        for (final match in matches) {
          if (normalizedTitle(match.title) == normalizedTitle(book.title)) {
            entries[source.key] = match;
            break;
          }
        }
      } catch (_) {
        // Keep existing source even if another site is temporarily unavailable.
      }
    }
    return UnifiedManga(title: book.title, entries: entries);
  }
}

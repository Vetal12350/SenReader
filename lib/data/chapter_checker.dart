import '../core/chapter_updates.dart';
import '../core/models.dart';
import '../core/source.dart';

class ChapterChecker {
  ChapterChecker(this.sources);
  final Map<String, MangaSource> sources;

  Future<ChapterCheckResult> check(Map<String, MangaEntry> entries,
      ChapterUpdateState previous) async {
    final detected = <ChapterRelease>[];
    final warnings = <String>[];
    var successful = 0;
    // Run linked sites concurrently. A slow first provider cannot win by priority.
    await Future.wait(entries.entries.map((entry) async {
      final source = sources[entry.key];
      if (source == null) {
        warnings.add('${entry.key}: источник недоступен');
        return;
      }
      try {
        final detail = await source.detail(entry.value);
        var verified = 0;
        var alreadySeen = 0;
        // Bound page-metadata requests to four per site. Do not download images.
        var index = 0;
        final requestedIds = <String>{};
        Future<void> verify() async {
          while (index < detail.chapters.length) {
            final chapter = detail.chapters[index++];
            if (!requestedIds.add(chapter.id)) continue;
            final key = canonicalChapterKey(chapter);
            if (!chapter.readable) continue;
            if (key == null) {
              warnings.add('${source.name} · ${chapter.name}: нет точного номера главы');
              continue;
            }
            if (previous.seen.contains(key) && !previous.inbox.containsKey(key)) {
              alreadySeen++;
              continue;
            }
            try {
              // Listing membership alone does not prove anonymous readability.
              // In particular this excludes page endpoints returning 403/locks.
              final pages = await source.pages(chapter);
              if (pages.isEmpty) {
                warnings.add('${source.name} · ${chapter.name}: публичные страницы недоступны');
                continue;
              }
              verified++;
              detected.add(ChapterRelease(source: entry.key, chapter: chapter,
                detectedAtMicros: DateTime.now().microsecondsSinceEpoch));
            } catch (e) {
              warnings.add('${source.name} · ${chapter.name}: $e');
            }
          }
        }
        await Future.wait(List.generate(4, (_) => verify()));
        // A listing whose every candidate reader is inaccessible cannot establish
        // a baseline; its first genuinely readable lookup must still be silent.
        if (verified > 0 || alreadySeen > 0 ||
            detail.chapters.every((chapter) => !chapter.readable)) successful++;
      } catch (e) {
        warnings.add('${source.name}: $e');
      }
    }));
    return reduceChapterCheck(previous, detected,
      successfulSources: successful, warnings: warnings);
  }
}

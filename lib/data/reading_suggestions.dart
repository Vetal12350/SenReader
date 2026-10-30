import '../core/chapter_identity.dart';
import '../core/models.dart';
import 'library_store.dart';

/// Only source-backed, chronologically newer unread chapters qualify for
/// "Продолжить чтение". A finished current chapter alone is not a suggestion.
Chapter? nextAvailableChapter(SavedBook saved, Iterable<Chapter> chapters) {
  if (saved.lastChapter.isEmpty || saved.lastSource.isEmpty ||
      saved.preferredSource != saved.lastSource ||
      saved.status == 'dropped' || saved.status == 'viewed') return null;
  final baseline = Chapter(
    id: saved.lastChapterId, name: saved.lastChapter);
  if (canonicalChapterKey(baseline) == null) return null;
  final candidates = chapters.where((chapter) {
    final order = compareChapterChronology(chapter, baseline);
    return order != null && order > 0 &&
        !saved.readChapterKeys.contains(
          sourceChapterKey(chapter, saved.lastSource));
  }).toList()..sort((a, b) => compareChapterChronology(a, b)!);
  return candidates.isEmpty ? null : candidates.first;
}

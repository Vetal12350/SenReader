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

/// Progress is independent from a suggestion that a newer chapter exists.
/// Never jump forward while the saved chapter has not been marked read.
bool shouldResumeCurrentChapter(SavedBook saved) {
  if (saved.lastChapter.isEmpty || saved.lastSource.isEmpty ||
      saved.lastSource != saved.preferredSource) return false;
  final chapter = Chapter(id: saved.lastChapterId, name: saved.lastChapter);
  // Opening a chapter immediately marks its eye, but a saved page before
  // the end must still resume even when its eye is already open.
  return saved.lastPageCount == 0 ||
      saved.lastPageIndex < saved.lastPageCount - 1;
}

Chapter? chapterToResume(SavedBook saved, Iterable<Chapter> available,
    {Chapter? nextUnread}) {
  final chapters = available.toList();
  final match = chapters.where((chapter) => saved.lastChapterId.isNotEmpty
      ? chapter.id == saved.lastChapterId
      : chapter.name == saved.lastChapter).toList();
  if (shouldResumeCurrentChapter(saved) && match.isNotEmpty) return match.first;
  if (nextUnread != null && chapters.any((chapter) => chapter.id == nextUnread.id) &&
      nextAvailableChapter(saved, chapters)?.id == nextUnread.id) {
    return chapters.firstWhere((chapter) => chapter.id == nextUnread.id);
  }
  return match.isNotEmpty ? match.first : null;
}

 
/// A title with its last known page completed is not an active resume card
/// unless the source confirmed a genuinely new unread chapter.
bool showContinueCard(SavedBook saved, {Chapter? newlyAvailable}) {
  if (saved.lastChapter.isEmpty || saved.lastSource != saved.preferredSource ||
      saved.status == 'completed' || saved.status == 'dropped' ||
      (saved.status == 'viewed' && saved.lastChapter.isEmpty)) return false;
  if (newlyAvailable != null) return true;
  if (!shouldResumeCurrentChapter(saved)) return false;
  if (saved.lastPageCount > 0 &&
      saved.lastPageIndex >= saved.lastPageCount - 1) return false;
  return true;
}

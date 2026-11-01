import '../core/chapter_identity.dart';
import '../core/models.dart';
import 'chapter_inbox_store.dart';
import 'library_store.dart';

/// Only source-backed, chronologically newer unread chapters qualify for
/// "Продолжить чтение". A finished current chapter alone is not a suggestion.
Chapter? nextAvailableChapter(SavedBook saved, Iterable<Chapter> chapters) {
  if (saved.status != 'reading' || saved.lastChapter.isEmpty ||
      saved.lastSource.isEmpty ||
      saved.preferredSource != saved.lastSource) return null;
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

/// An old cached suggestion stops being new as soon as its chapter is
/// opened/read, or when the saved chapter advances to the same number.
/// This guard is also used when the home page was not refreshed.
Chapter? eligibleNewChapter(SavedBook saved, Chapter? candidate) {
  if (candidate == null || saved.status != 'reading' ||
      saved.lastChapter.isEmpty || saved.lastSource.isEmpty ||
      saved.lastSource != saved.preferredSource) return null;
  final last = Chapter(id: saved.lastChapterId, name: saved.lastChapter);
  final order = compareChapterChronology(candidate, last);
  if (order == null || order <= 0) return null;
  if (saved.readChapterKeys.contains(
      sourceChapterKey(candidate, saved.lastSource))) return null;
  return candidate;
}

/// Already verified inbox discoveries can feed Continue without another
/// network scan of the same books. Ignore archives, alternate translations,
/// unlinked and already-read chapters. Earliest unread chapter wins.
Map<String, Chapter> unreadInboxSuggestions(Iterable<SavedBook> savedBooks,
    Iterable<InboxEntry> inbox) {
  final books = {for (final book in savedBooks) book.key: book};
  final suggestions = <String, Chapter>{};
  for (final entry in inbox) {
    if (entry.hidden) continue;
    final saved = books[entry.bookKey];
    if (saved == null || saved.preferredSource != entry.source ||
        !saved.entries.containsKey(entry.source)) continue;
    final chapter = Chapter(id: entry.chapterId, name: entry.chapterName);
    final candidate = eligibleNewChapter(saved, chapter);
    if (candidate == null) continue;
    final previous = suggestions[saved.key];
    if (previous == null ||
        (compareChapterChronology(candidate, previous) ?? 1) < 0) {
      suggestions[saved.key] = candidate;
    }
  }
  return suggestions;
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
      saved.status == 'completed' || saved.status == 'dropped') return false;
  if (eligibleNewChapter(saved, newlyAvailable) != null) return true;
  // Even when partially read, the current LAST available chapter should
  // not appear in Continue: it is not a remaining chapter to catch up on.
  if (saved.latestKnownSource == saved.lastSource &&
      saved.latestKnownChapterId.isNotEmpty &&
      saved.latestKnownChapterId == saved.lastChapterId) return false;
  if (!shouldResumeCurrentChapter(saved)) return false;
  if (saved.lastPageCount > 0 &&
      saved.lastPageIndex >= saved.lastPageCount - 1) return false;
  return true;
}

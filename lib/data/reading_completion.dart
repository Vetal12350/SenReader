/// Pure guard used by the reader to avoid marking an opened, skipped or
/// failed image chapter as completed. Only a full forward pass qualifies.
bool chapterFullyRead({
  required bool forwardScrolled,
  required bool passedChapterBoundary,
  required int pageCount,
  required Iterable<int> loadedPages,
  required bool alreadyCompleted,
}) {
  if (!forwardScrolled || !passedChapterBoundary ||
      alreadyCompleted || pageCount <= 0) return false;
  final seen = loadedPages.toSet();
  for (var index = 0; index < pageCount; index++) {
    if (!seen.contains(index)) return false;
  }
  return true;
}

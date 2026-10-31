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

/// The last loaded chapter can be completed at the genuine scroll end even
/// while the reader is still trying to fetch the next chapter. The next
/// chapter's network state does not determine whether this one was read.
bool terminalChapterBoundaryReached({
  required bool forwardScrolled,
  required bool reachedScrollableEnd,
  required bool footerVisible,
}) => forwardScrolled && reachedScrollableEnd && footerVisible;

/// After a continuous-chapter transition, the previous chapter is past the
/// viewport once the separator is the first visible item. The next chapter's
/// first image need not have loaded or entered the screen yet.
bool previousChapterBoundaryReached({
  required int boundaryIndex,
  required Iterable<int> visibleItemIndexes,
}) {
  final visible = visibleItemIndexes.toList();
  return visible.isNotEmpty &&
      visible.every((index) => index >= boundaryIndex);
}

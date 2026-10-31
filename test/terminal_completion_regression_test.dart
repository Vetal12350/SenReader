import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/reading_completion.dart';

void main() {
  test('read last chapter at scroll end without next-chapter network status', () {
    expect(terminalChapterBoundaryReached(
      forwardScrolled: true,
      reachedScrollableEnd: true,
      footerVisible: true,
    ), isTrue);
    expect(chapterFullyRead(
      forwardScrolled: true,
      passedChapterBoundary: true,
      pageCount: 3,
      loadedPages: [0, 1, 2],
      alreadyCompleted: false,
    ), isTrue);
  });

  test('opening at footer or failing a page never auto-completes', () {
    expect(terminalChapterBoundaryReached(
      forwardScrolled: false,
      reachedScrollableEnd: true,
      footerVisible: true,
    ), isFalse);
    expect(terminalChapterBoundaryReached(
      forwardScrolled: true,
      reachedScrollableEnd: false,
      footerVisible: true,
    ), isFalse);
    expect(terminalChapterBoundaryReached(
      forwardScrolled: true,
      reachedScrollableEnd: true,
      footerVisible: false,
    ), isFalse);
    expect(chapterFullyRead(
      forwardScrolled: true,
      passedChapterBoundary: true,
      pageCount: 3,
      loadedPages: [0, 2],
      alreadyCompleted: false,
    ), isFalse);
  });

  test('past chapter separator counts without loading next page', () {
    expect(previousChapterBoundaryReached(
      boundaryIndex: 18, visibleItemIndexes: [18]), isTrue);
    expect(previousChapterBoundaryReached(
      boundaryIndex: 18, visibleItemIndexes: [18, 19]), isTrue);
    expect(previousChapterBoundaryReached(
      boundaryIndex: 18, visibleItemIndexes: [17, 18]), isFalse);
    expect(previousChapterBoundaryReached(
      boundaryIndex: 18, visibleItemIndexes: []), isFalse);
  });

  test('user override blocks automatic re-completion', () {
    expect(chapterFullyRead(
      forwardScrolled: true,
      passedChapterBoundary: true,
      pageCount: 1,
      loadedPages: [0],
      alreadyCompleted: true,
    ), isFalse);
  });
}

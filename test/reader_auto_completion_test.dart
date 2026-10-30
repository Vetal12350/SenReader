import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/reading_completion.dart';

void main() {
  test('only real reading through every loaded page completes a chapter', () {
    expect(chapterFullyRead(forwardScrolled: true,
      passedChapterBoundary: true, pageCount: 3,
      loadedPages: [0, 1, 2], alreadyCompleted: false), true);
    for (final missingPage in [0, 1, 2]) {
      expect(chapterFullyRead(forwardScrolled: true,
        passedChapterBoundary: true, pageCount: 3,
        loadedPages: [for (var i=0;i<3;i++) if(i!=missingPage) i],
        alreadyCompleted: false), false);
    }
  });
  test('no auto-read on opening last page, empty chapter or failed images', () {
    expect(chapterFullyRead(forwardScrolled: false,
      passedChapterBoundary: true, pageCount: 1,
      loadedPages: [0], alreadyCompleted: false), false);
    expect(chapterFullyRead(forwardScrolled: true,
      passedChapterBoundary: false, pageCount: 1,
      loadedPages: [0], alreadyCompleted: false), false);
    expect(chapterFullyRead(forwardScrolled: true,
      passedChapterBoundary: true, pageCount: 0,
      loadedPages: [], alreadyCompleted: false), false);
    expect(chapterFullyRead(forwardScrolled: true,
      passedChapterBoundary: true, pageCount: 2,
      loadedPages: [0], alreadyCompleted: false), false);
    expect(chapterFullyRead(forwardScrolled: true,
      passedChapterBoundary: true, pageCount: 1,
      loadedPages: [0], alreadyCompleted: true), false);
  });
}

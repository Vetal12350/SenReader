import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/chapter_identity.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/reading_suggestions.dart';

void main() {
  final entry = <String, MangaEntry>{
    'readmanga': const MangaEntry(source: 'readmanga', id: '/test',
      title: 'Title'),
    'senkuro': const MangaEntry(source: 'senkuro', id: 'title',
      title: 'Title'),
  };
  const chapters = [
    Chapter(id: '127', name: 'Глава 127 (т. 2)'),
    Chapter(id: '126', name: 'Глава 126 (т. 2)'),
    Chapter(id: '125', name: 'Глава 125 (т. 2)'),
  ];
  SavedBook saved({String last = 'Глава 126 (т. 2)',
    String lastSource = 'readmanga', String preferred = 'readmanga',
    String status = 'reading', Set<String>? read}) =>
      SavedBook(title: 'Title', entries: entry, lastChapter: last,
        lastChapterId: 'last', lastSource: lastSource, preferredSource: preferred,
        status: status, readChapterKeys: read);

  test('unread current chapter always wins over new chapter on resume', () {
    final record = saved(last: 'Глава 126 (т. 2)');
    record.lastChapterId = '126';
    record.lastPageIndex = 0;
    record.lastPageCount = 16;
    expect(shouldResumeCurrentChapter(record), isTrue);
    expect(chapterToResume(record, chapters, nextUnread: chapters.first)?.id, '126');
  });

  test('read current chapter may advance to new unread chapter', () {
    final record = saved(last: 'Глава 126 (т. 2)');
    record.lastChapterId = '126';
    record.readChapterKeys.add(sourceChapterKey(
      const Chapter(id: '126', name: 'Глава 126 (т. 2)'), 'readmanga'));
    expect(shouldResumeCurrentChapter(record), isFalse);
    expect(chapterToResume(record, chapters, nextUnread: chapters.first)?.id, '127');
  });

  test('fully completed final chapter disappears from Continue, new verified chapter returns', () {
    final record = saved(last: 'Глава 127 (т. 2)');
    record.lastChapterId = '127';
    record.lastPageIndex = 66;
    record.lastPageCount = 67;
    expect(showContinueCard(record), false);
    expect(showContinueCard(record, newlyAvailable: const Chapter(
      id: '128', name: 'Глава 128 (т. 2)')), true);
    record.lastPageIndex = 32;
    expect(showContinueCard(record), true);
    record.status = 'completed';
    expect(showContinueCard(record), false);
  });

  test('current newest chapter never appears in continue-reading', () {
    expect(nextAvailableChapter(
      saved(last: 'Глава 127 (т. 2)'), chapters), isNull);
  });
  test('saves the position but only suggests genuinely newer chapters', () {
    final record = saved();
    record.lastPageCount = 108;
    record.lastPageIndex = 107;
    expect(nextAvailableChapter(record, chapters)?.id, '127');
    expect(nextAvailableChapter(record,
      chapters.where((c) => c.id != '127')), isNull);
  });
  test('does not suggest a chapter already marked read', () {
    expect(nextAvailableChapter(saved(read: {'readmanga|v2:c127'}),
      chapters), isNull);
  });
  test('no suggestions for alternate source, dropped or never opened', () {
    expect(nextAvailableChapter(saved(preferred: 'senkuro'),
      chapters), isNull);
    expect(nextAvailableChapter(saved(status: 'dropped'),
      chapters), isNull);
    expect(nextAvailableChapter(saved(last: ''),
      chapters), isNull);
    expect(nextAvailableChapter(saved(last: 'Спецвыпуск'),
      chapters), isNull);
  });
  test('decimal and volume sorting finds earliest later chapter', () {
    final set = [
      const Chapter(id: '3', name: 'Глава 1 (т. 3)'),
      const Chapter(id: 'b', name: 'Глава 9.6 (т. 2)'),
      const Chapter(id: 'a', name: 'Глава 9.51 (т. 2)'),
    ];
    expect(nextAvailableChapter(saved(last: 'Глава 9.5 (т. 2)'),
      set)?.id, 'a');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/chapter_identity.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/reading_suggestions.dart';
import 'package:senreader/data/chapter_inbox_store.dart';

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
    record.lastPageCount = 16;
    record.lastPageIndex = 15;
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

  test('selected latest chapter is hidden even at page 77/78', () {
    final record = saved(last: 'Глава 127 (т. 2)');
    record.lastChapterId = '127';
    record.lastPageIndex = 76;
    record.lastPageCount = 78;
    record.latestKnownChapterId = '127';
    record.latestKnownSource = 'readmanga';
    expect(shouldResumeCurrentChapter(record), true);
    expect(showContinueCard(record), false);
    expect(showContinueCard(record,
      newlyAvailable: const Chapter(id: '128', name: 'Глава 128 (т. 2)')), true);
    record.lastChapterId = '126';
    expect(showContinueCard(record), true);
  });

  test('new unread inbox chapter appears even without a home source scan', () {
    final record = saved(last: 'Глава 112');
    record.lastChapterId = '112';
    record.lastPageCount = 14;
    record.lastPageIndex = 13;
    record.latestKnownChapterId = '112';
    record.latestKnownSource = 'readmanga';
    const latest = InboxEntry(
      key: 'title|readmanga|v0:c113', bookKey: 'title',
      title: 'Title', coverUrl: '', source: 'readmanga',
      chapterId: '113', chapterName: 'Глава 113', createdAt: 1);
    final suggestions = unreadInboxSuggestions([record], [latest]);
    expect(suggestions[record.key]?.id, '113');
    expect(showContinueCard(record, newlyAvailable: suggestions[record.key]), true);
  });

  test('last chapter read at 14/14 removes stale Continue suggestion', () {
    final record = saved(last: 'Глава 112');
    record.lastChapterId = '112';
    record.lastPageCount = 14;
    record.lastPageIndex = 13;
    record.latestKnownChapterId = '113';
    record.latestKnownSource = 'readmanga';
    const chapter113 = Chapter(id: '113', name: 'Глава 113');
    expect(showContinueCard(record, newlyAvailable: chapter113), true);
    // Reader saved the newly opened chapter and completion marker.
    record.lastChapterId = '113';
    record.lastChapter = 'Глава 113';
    record.readChapterKeys.add(sourceChapterKey(chapter113, 'readmanga'));
    expect(eligibleNewChapter(record, chapter113), isNull);
    expect(showContinueCard(record, newlyAvailable: chapter113), false);
  });

  test('planned and completed titles never produce chapter suggestions', () {
    const alert = InboxEntry(
      key: 'title|readmanga|v0:c127', bookKey: 'title',
      title: 'Title', coverUrl: '', source: 'readmanga',
      chapterId: '127', chapterName: 'Глава 127 (т. 2)', createdAt: 1);
    for (final status in ['planned', 'completed', 'viewed', 'dropped']) {
      final record = saved(status: status);
      record.lastChapterId = '126';
      expect(nextAvailableChapter(record, chapters), isNull,
          reason: 'unexpected network candidate for $status');
      expect(eligibleNewChapter(record, chapters.first), isNull,
          reason: 'unexpected cached candidate for $status');
      expect(unreadInboxSuggestions([record], [alert]), isEmpty,
          reason: 'unexpected inbox suggestion for $status');
      expect(showContinueCard(record, newlyAvailable: chapters.first), false,
          reason: 'unexpected Continue card for $status');
    }
  });

  test('read, hidden, alternate-source and old inbox updates do not reappear', () {
    final record = saved(last: 'Глава 112');
    record.lastChapterId = '112';
    const latest = InboxEntry(
      key: 'title|readmanga|v0:c113', bookKey: 'title',
      title: 'Title', coverUrl: '', source: 'readmanga',
      chapterId: '113', chapterName: 'Глава 113', createdAt: 1);
    expect(unreadInboxSuggestions([record], [latest.hide(10)]), isEmpty);
    expect(unreadInboxSuggestions([record], [
      const InboxEntry(key: 'title|senkuro|v0:c113', bookKey: 'title',
        title: 'Title', coverUrl: '', source: 'senkuro',
        chapterId: '113', chapterName: 'Глава 113', createdAt: 1),
    ]), isEmpty);
    record.readChapterKeys.add('readmanga|v0:c113');
    expect(unreadInboxSuggestions([record], [latest]), isEmpty);
    record.readChapterKeys.clear();
    record.lastChapter = 'Глава 114';
    expect(unreadInboxSuggestions([record], [latest]), isEmpty);
  });

  test('multiple inbox chapters choose earliest unread chapter', () {
    final record = saved(last: 'Глава 112');
    record.lastChapterId = '112';
    final updates = [115, 113, 114].map((number) => InboxEntry(
      key: 'title|readmanga|v0:c$number', bookKey: 'title',
      title: 'Title', coverUrl: '', source: 'readmanga',
      chapterId: '$number', chapterName: 'Глава $number',
      createdAt: number));
    expect(unreadInboxSuggestions([record], updates)[record.key]?.id, '113');
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

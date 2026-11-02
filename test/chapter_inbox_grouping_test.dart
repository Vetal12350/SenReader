import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/ui/chapter_inbox_grouping.dart';

InboxEntry _chapter(String book, String source, String id, int at,
    {int hiddenAt = 0, String? name}) => InboxEntry(
  key: book + '|' + source + '|v0:c' + id,
  bookKey: book, title: book, coverUrl: '', source: source,
  chapterId: id, chapterName: name ?? 'Глава ' + id,
  createdAt: at, hiddenAt: hiddenAt,
);

void main() {
  test('one card per manga, chapters sorted by chapter number not insertion order', () {
    final rows = [
      _chapter('story', 'readmanga', '178', 50),
      _chapter('story', 'readmanga', '177', 100),
      _chapter('other', 'senkuro', '5', 70),
    ];
    final groups = groupInboxChapters(rows, hidden: false);
    expect(groups.length, 2);
    final story = groups.firstWhere((g) => g.latest.bookKey == 'story');
    expect(story.entries.map((e) => e.chapterId), ['178', '177']);
    expect(story.chapterLabel, 'Главы 177–178');
    expect(story.latest.chapterId, '178');
    expect(story.newestAt, 100);
    expect(groups.singleWhere((g) => g.latest.bookKey == 'other')
        .chapterLabel, 'Глава 5');
  });

  test('visible and archived chapters never contaminate each other', () {
    final rows = [
      _chapter('story', 'readmanga', '177', 100, hiddenAt: 200),
      _chapter('story', 'readmanga', '178', 101),
      _chapter('other', 'senkuro', '5', 99),
    ];
    final active = groupInboxChapters(rows, hidden: false);
    final archived = groupInboxChapters(rows, hidden: true);
    expect(active.length, 2);
    expect(active.first.chapterLabel, 'Глава 178');
    expect(archived.length, 1);
    expect(archived.single.chapterLabel, 'Глава 177');
  });

  test('nonsequential and unusual chapter names are never falsely merged into a range', () {
    expect(InboxChapterGroup([
      _chapter('story', 'readmanga', '175', 1),
      _chapter('story', 'readmanga', '178', 2),
    ]).chapterLabel, 'Главы 175, 178');
    expect(InboxChapterGroup([
      _chapter('story', 'readmanga', 'a', 1, name: 'Спецвыпуск'),
      _chapter('story', 'readmanga', 'b', 2, name: 'Глава 179'),
    ]).chapterLabel, 'Новых глав: 2 · Глава 179');
  });
}

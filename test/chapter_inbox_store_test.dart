import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_inbox_store.dart';

InboxEntry entry(int number, {bool hidden = true, String book = 'a'}) =>
  InboxEntry(key: book + '|senkuro|v0:c' + number.toString(),
    bookKey: book, title: 'Sample', coverUrl: '', source: 'senkuro',
    chapterId: number.toString(), chapterName: 'Глава ' + number.toString(),
    createdAt: number, hiddenAt: hidden ? number : 0);

void main() {
  test('keep newest 50 hidden and preserve all new entries independently', () {
    final items = [
      for (var i = 1; i <= 80; i++) entry(i),
      entry(81, hidden: false),
      entry(82, hidden: false, book: 'other'),
    ];
    final trimmed = ChapterInboxStore.trim(items);
    expect(trimmed.where((e) => e.hidden).length, 50);
    expect(trimmed.where((e) => e.hidden).map((e) => e.chapterId).contains('1'), false);
    expect(trimmed.where((e) => e.hidden).map((e) => e.chapterId).contains('80'), true);
    expect(trimmed.where((e) => !e.hidden).length, 2);
  });
}

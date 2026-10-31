import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final book = UnifiedManga(title: 'Статусы QA', entries: {
    'senkuro': const MangaEntry(source: 'senkuro', id: 'title', title: 'Статусы QA'),
    'readmanga': const MangaEntry(source: 'readmanga', id: '/title', title: 'Статусы QA'),
  });
  final chapters = List.generate(7, (i) =>
    Chapter(id: '${121+i}', name: 'Глава ${121+i} (т. 2)'));

  test('a title viewed for the first time is not planned; status never downgrades', () async {
    final store = LibraryStore();
    await store.markViewed(book);
    expect(store.get(book)!.status, 'viewed');
    await store.setStatus(book, 'planned', preferredSource: 'senkuro');
    await store.markViewed(book);
    expect(store.get(book)!.status, 'planned');
    await store.setStatus(book, 'dropped');
    await store.markViewed(book);
    expect(store.get(book)!.status, 'dropped');
    final reloaded = LibraryStore();
    await reloaded.load();
    expect(reloaded.get(book)!.status, 'dropped');
  });

  test('favorite is independent of status and survives JSON export/reload', () async {
    final store = LibraryStore();
    await store.setFavorite(book, true);
    expect(store.get(book)!.status, 'viewed');
    expect(store.get(book)!.favorite, true);
    await store.setStatus(book, 'reading');
    expect(store.get(book)!.favorite, true);
    final snapshot = store.get(book)!.toJson();
    expect(snapshot['favorite'], true);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.get(book)!.favorite, true);
    expect(restored.get(book)!.status, 'reading');
    await restored.setFavorite(book, false);
    expect(restored.get(book)!.favorite, false);
    expect(restored.get(book)!.status, 'reading');
  });

  test('reading progress and open eye do not auto-enroll a title in bookmarks', () async {
    final store = LibraryStore();
    await store.savePosition(book, chapters[3], 'senkuro',
      pageIndex: 4, pageCount: 18);
    await store.markRead(book, chapters[3], 'senkuro',
      availableChapters: chapters);
    final entry = store.get(book)!;
    expect(entry.status, 'viewed'); // Passive history, not an explicit bookmark.
    expect(entry.lastPageIndex, 4);
    expect(store.isChapterRead(book, chapters[3], 'senkuro'), true);
    await store.unmarkRead(book, chapters[2], 'senkuro',
      availableChapters: chapters);
    expect(store.get(book)!.lastChapterId, chapters[2].id);
    expect(store.get(book)!.lastPageIndex, 0);
    expect(store.isChapterRead(book, chapters[2], 'senkuro'), false);
  });

  test('legacy JSON without favorite remains readable', () {
    final raw = SavedBook(title: book.title, entries: book.entries,
      status: 'planned').toJson()..remove('favorite');
    expect(SavedBook.fromJson(raw).favorite, false);
    expect(SavedBook.fromJson(raw).status, 'planned');
    final newRecord = {...raw, 'status': 'viewed', 'favorite': true};
    expect(SavedBook.fromJson(newRecord).status, 'viewed');
    expect(SavedBook.fromJson(newRecord).favorite, true);
    expect(jsonEncode(SavedBook.fromJson(newRecord).toJson()), contains('"favorite":true'));
  });

  test('unreading 123 makes 123..127 unread, older chapters remain read', () async {
    final store = LibraryStore();
    await store.savePosition(book, chapters[5], 'senkuro',
      pageIndex: 6, pageCount: 18);
    await store.markRead(book, chapters.last, 'senkuro',
      availableChapters: chapters);
    expect(chapters.every((c) => store.isChapterRead(book, c, 'senkuro')), true);
    await store.unmarkRead(book, chapters[2], 'senkuro',
      availableChapters: chapters.reversed);
    for (var i = 0; i < chapters.length; i++) {
      expect(store.isChapterRead(book, chapters[i], 'senkuro'),
        i < 2, reason: chapters[i].name);
    }
    expect(store.get(book)!.lastChapterId, chapters[2].id);
    expect(store.get(book)!.lastPageIndex, 0);
    expect(store.get(book)!.lastPageCount, 0);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.isChapterRead(book, chapters[6], 'senkuro'), false);
    expect(restored.isChapterRead(book, chapters[1], 'senkuro'), true);
  });

  test('cascading unread stops at source boundary and respects volume', () async {
    const old = Chapter(id: 'old', name: 'Глава 999 (т. 1)');
    const next = Chapter(id: 'new', name: 'Глава 1 (т. 3)');
    final all = [...chapters, old, next];
    final store = LibraryStore();
    await store.markRead(book, next, 'senkuro', availableChapters: all);
    await store.unmarkRead(book, chapters[2], 'senkuro',
      availableChapters: all);
    expect(store.isChapterRead(book, old, 'senkuro'), true);
    expect(store.isChapterRead(book, next, 'senkuro'), false);
    await store.setPreferredSource(book, 'readmanga');
    await store.markRead(book, chapters[6], 'readmanga',
      availableChapters: chapters);
    await store.unmarkRead(book, chapters[2], 'readmanga',
      availableChapters: chapters);
    expect(store.isChapterRead(book, chapters[6], 'readmanga'), false);
    expect(store.isChapterRead(book, old, 'senkuro'), true);
    expect(store.isChapterRead(book, chapters[0], 'senkuro'), true);
  });
}

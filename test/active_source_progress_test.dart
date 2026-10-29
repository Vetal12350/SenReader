import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/library_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final book = UnifiedManga(title: 'Example', entries: {
    'remanga': const MangaEntry(source: 'remanga', id: 'r', title: 'Example'),
    'senkuro': const MangaEntry(source: 'senkuro', id: 's', title: 'Example'),
    'readmanga': const MangaEntry(source: 'readmanga', id: '/test', title: 'Example'),
  });
  const chapters = [
    Chapter(id: 'newer', name: 'Глава 10 (т. 2)'),
    Chapter(id: 'old-volume', name: 'Глава 99 (т. 1)'),
    Chapter(id: 'target', name: 'Глава 9.5 (т. 2)'),
    Chapter(id: 'older', name: 'Глава 9.05 (т. 2)'),
    Chapter(id: 'special', name: 'Спецвыпуск'),
    Chapter(id: 'latest', name: 'Глава 1 (т. 3)'),
  ];

  test('legacy source migration is deterministic and retains metadata/baselines', () {
    final raw = SavedBook(title: book.title, entries: book.entries,
      lastSource: 'readmanga', lastChapter: 'Глава 7',
      seenChapterKeys: {'v0:c1'}, initializedSources: {'senkuro', 'readmanga'}).toJson()
      ..remove('preferredSource');
    final migrated = SavedBook.fromJson(raw);
    expect(migrated.preferredSource, 'readmanga');
    expect(migrated.entries.map((key, value) => MapEntry(key, value.toJson())),
        book.entries.map((key, value) => MapEntry(key, value.toJson())));
    expect(migrated.seenChapterKeys, {'v0:c1'});
    expect(migrated.initializedSources, {'senkuro', 'readmanga'});
    expect(migrated.lastChapter, 'Глава 7');
    raw['lastSource'] = 'unknown';
    expect(SavedBook.fromJson(raw).preferredSource, 'senkuro');
    raw['preferredSource'] = 'remanga';
    expect(SavedBook.fromJson(raw).preferredSource, 'remanga');
  });

  test('explicit source persists through discovery/status, transfer and reload', () async {
    final store = LibraryStore();
    await store.add(book, preferredSource: 'remanga');
    await store.savePosition(book, chapters[2], 'remanga', pageIndex: 4, pageCount: 12);
    await store.markRead(book, chapters[2], 'remanga', availableChapters: chapters);
    await store.recordChapterScan(store.items.single.key, 'remanga', ['v2:c9.5']);
    await store.setPreferredSource(book, 'senkuro');
    await store.add(book);
    await store.setStatus(book, 'completed', preferredSource: 'readmanga');
    final restored = LibraryStore();
    await restored.load();
    final saved = restored.items.single;
    expect(saved.preferredSource, 'senkuro');
    expect(saved.lastSource, 'remanga');
    expect(saved.lastChapterId, 'target');
    expect(saved.lastPageIndex, 4);
    expect(saved.entries.keys, containsAll(book.entries.keys));
    expect(saved.seenChapterKeys, {'v2:c9.5'});
    expect(restored.isChapterRead(book, chapters[2], 'senkuro'), false);
    final codec = LibraryTransfer();
    final backup = codec.parse(codec.exportBooks([saved]));
    final transferred = SavedBook.fromJson(backup.books.single.toJson());
    expect(transferred.toJson(), saved.toJson());
    await restored.setPreferredSource(book, 'remanga');
    expect(restored.isChapterRead(book, chapters[2], 'remanga'), true);
  });

  for (final reverse in [false, true]) {
    test('cumulative marks use numeric volumes/decimals, reversed=$reverse', () async {
      final store = LibraryStore();
      await store.savePosition(book, chapters.first, 'senkuro', pageIndex: 7, pageCount: 20);
      final resume = store.items.single.toJson();
      await store.markRead(book, chapters[2], 'senkuro',
          availableChapters: reverse ? chapters.reversed : chapters);
      for (final index in [1, 2, 3]) {
        expect(store.isChapterRead(book, chapters[index], 'senkuro'), true);
      }
      for (final index in [0, 4, 5]) {
        expect(store.isChapterRead(book, chapters[index], 'senkuro'), false);
      }
      await store.unmarkRead(book, chapters[2], 'senkuro');
      expect(store.isChapterRead(book, chapters[2], 'senkuro'), false);
      expect(store.isChapterRead(book, chapters[1], 'senkuro'), true);
      final restored = LibraryStore();
      await restored.load();
      expect(restored.isChapterRead(book, chapters[2], 'senkuro'), false);
      for (final field in ['lastChapter', 'lastChapterId', 'lastSource',
          'lastPageIndex', 'lastPageCount', 'lastUpdatedAt']) {
        expect(restored.items.single.toJson()[field], resume[field]);
      }
    });
  }

  test('unparseable selection marks only its exact source-scoped identity', () async {
    final store = LibraryStore();
    await store.markRead(book, chapters[4], 'senkuro', availableChapters: chapters);
    expect(store.isChapterRead(book, chapters[4], 'senkuro'), true);
    expect(store.isChapterRead(book, chapters[4], 'remanga'), false);
    expect(store.isChapterRead(book, const Chapter(id: 'other', name: 'Спецвыпуск'), 'senkuro'), false);
    for (final chapter in chapters.where((chapter) => chapter.id != 'special')) {
      expect(store.isChapterRead(book, chapter, 'senkuro'), false);
    }
  });

  test('legacy read history stays on original source and unread survives reload', () async {
    final raw = SavedBook(title: book.title, entries: book.entries,
      lastSource: 'remanga', lastChapter: 'Глава 9.5 (т. 2)',
      readChapterKeys: {'v2:c9.5'}).toJson()
      ..remove('readHistoryVersion')
      ..remove('preferredSource');
    SharedPreferences.setMockInitialValues({LibraryStore.storageKey: jsonEncode([raw])});
    final store = LibraryStore();
    await store.load();
    expect(store.isChapterRead(book, chapters[2], 'remanga'), true);
    await store.setPreferredSource(book, 'senkuro');
    await store.savePosition(book, chapters[2], 'senkuro', pageIndex: 2, pageCount: 8);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.isChapterRead(book, chapters[2], 'senkuro'), false);
    expect(restored.isChapterRead(book, chapters[2], 'remanga'), true);
    await restored.setPreferredSource(book, 'remanga');
    await restored.unmarkRead(book, chapters[2], 'remanga');
    await restored.load();
    expect(restored.isChapterRead(book, chapters[2], 'remanga'), false);
  });

  test('stale reader and scan cannot change active preference or resume', () async {
    final foreground = LibraryStore();
    await foreground.savePosition(book, chapters[2], 'senkuro', pageIndex: 3, pageCount: 9);
    final stale = LibraryStore();
    await stale.load();
    await foreground.setPreferredSource(book, 'remanga');
    await stale.recordChapterScan(stale.items.single.key, 'senkuro', ['v0:c999']);
    await stale.savePosition(book, chapters.first, 'senkuro', pageIndex: 0, pageCount: 1);
    await stale.markRead(book, chapters.first, 'senkuro');
    await foreground.load();
    expect(foreground.items.single.preferredSource, 'remanga');
    expect(foreground.items.single.lastPageIndex, 3);
    expect(foreground.items.single.seenChapterKeys, isEmpty);
    expect(foreground.isChapterRead(book, chapters.first, 'senkuro'), false);
  });

  test('unattributed legacy completions are retained without guessing a source', () async {
    final raw = SavedBook(title: book.title, entries: book.entries,
      readChapterKeys: {'v2:c9.5'}).toJson()..remove('readHistoryVersion');
    SharedPreferences.setMockInitialValues({LibraryStore.storageKey: jsonEncode([raw])});
    final store = LibraryStore();
    await store.load();
    expect(store.items.single.readChapterKeys, contains('v2:c9.5'));
    for (final source in book.entries.keys) {
      expect(store.isChapterRead(book, chapters[2], source), false);
    }
  });
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const chapter = Chapter(id: 'chapter-17', name: 'Глава 17 (т. 2)');
  final book = UnifiedManga(title: 'Test series', entries: {
    'readmanga': const MangaEntry(
      source: 'readmanga', id: '/test', title: 'Test series',
    ),
  });

  test('page position survives store reload without marking chapter read', () async {
    final library = LibraryStore();
    await library.load();
    await library.savePosition(book, chapter, 'readmanga',
      pageIndex: 7, pageCount: 18);
    expect(library.isChapterRead(book, chapter, 'readmanga'), false);
    final restored = LibraryStore();
    await restored.load();
    final saved = restored.get(book)!;
    expect(saved.lastChapterId, chapter.id);
    expect(saved.lastPageIndex, 7);
    expect(saved.lastPageCount, 18);
    expect(saved.lastChapter, chapter.name);
    expect(saved.lastSource, 'readmanga');
    expect(saved.lastUpdatedAt, greaterThan(0));
  });

  test('manual completion is durable and reversible', () async {
    final library = LibraryStore();
    await library.load();
    await library.savePosition(book, chapter, 'readmanga',
      pageIndex: 2, pageCount: 18);
    await library.markRead(book, chapter, 'readmanga');
    final restored = LibraryStore();
    await restored.load();
    expect(restored.isChapterRead(book, chapter, 'readmanga'), true);
    expect(restored.get(book)!.lastPageIndex, 17);
    await restored.unmarkRead(book, chapter, 'readmanga');
    expect(restored.isChapterRead(book, chapter, 'readmanga'), false);
    expect(restored.get(book)!.lastChapterId, chapter.id);
  });

  test('existing v1 records load safely and remain intact', () async {
    const legacy = '[{"title":"Test series","entries":{'
      '"readmanga":{"source":"readmanga","id":"/test",'
      '"title":"Test series","coverUrl":""}},'
      '"lastChapter":"Глава 17 (т. 2)","lastSource":"readmanga"}]';
    SharedPreferences.setMockInitialValues({LibraryStore.storageKey: legacy});
    final library = LibraryStore();
    await library.load();
    expect(library.get(book)!.lastChapter, chapter.name);
    expect(library.isChapterRead(book, chapter, 'readmanga'), true);
    await library.savePosition(book, chapter, 'readmanga',
        pageIndex: 4, pageCount: 10);
    final raw = (await SharedPreferences.getInstance())
        .getString(LibraryStore.storageKey)!;
    expect(jsonDecode(raw).single['lastPageIndex'], 4);
  });
}

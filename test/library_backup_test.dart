import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';

void main() {
  const chapter = Chapter(id: 'chapter-4', name: 'Глава 4 (т. 1)');
  final book = UnifiedManga(title: 'Книга', entries: {
    'senkuro': const MangaEntry(
      source: 'senkuro', id: 'book', title: 'Книга'),
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('backup roundtrip keeps chapters, source, progress, favorites, and scan baseline', () async {
    final original = LibraryStore();
    await original.add(book, preferredSource: 'senkuro');
    await original.setFavorite(book, true);
    await original.savePosition(book, chapter, 'senkuro', pageIndex: 3, pageCount: 18);
    await original.markRead(book, chapter, 'senkuro', availableChapters: [chapter]);
    await original.recordChapterScan(book.title.toLowerCase(), 'senkuro', ['v1:c4']);
    final backup = await original.exportBackup();
    expect(original.previewBackup(backup).books, 1);

    SharedPreferences.setMockInitialValues({});
    final restored = LibraryStore();
    final result = await restored.importBackup(backup);
    expect(result.added, 1);
    expect(result.skipped, 0);
    final saved = restored.get(book)!;
    expect(saved.favorite, isTrue);
    expect(saved.preferredSource, 'senkuro');
    expect(saved.status, 'planned'); // The user did not explicitly choose a new status.
    expect(saved.lastPageIndex, 3);
    expect(saved.lastPageCount, 18);
    expect(saved.initializedSources, contains('senkuro'));
    expect(restored.isChapterRead(book, chapter, 'senkuro'), isTrue);
  });

  test('import never replaces existing book or deletes local progress', () async {
    final initial = LibraryStore();
    await initial.add(book, preferredSource: 'senkuro');
    await initial.savePosition(book, chapter, 'senkuro', pageIndex: 12, pageCount: 18);
    final backup = await initial.exportBackup();
    await initial.savePosition(book, chapter, 'senkuro', pageIndex: 16, pageCount: 18);
    final stats = await initial.importBackup(backup);
    expect(stats.added, 0);
    expect(stats.skipped, 1);
    expect(initial.get(book)!.lastPageIndex, 16);
  });

  test('rejects malformed and unknown backups before writing', () async {
    final store = LibraryStore();
    expect(() => store.previewBackup('{"books":[]}'), throwsFormatException);
    expect(() => store.previewBackup('not json'), throwsFormatException);
    expect(store.items, isEmpty);
  });
}

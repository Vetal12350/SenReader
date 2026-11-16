import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/reading_suggestions.dart';

/// «Читаемое сейчас» must drop a title once its newest known chapter is read,
/// and bring it back when a newer chapter becomes known.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const c128 = Chapter(id: '128', name: 'Глава 128');
  const c129 = Chapter(id: '129', name: 'Глава 129');
  const c130 = Chapter(id: '130', name: 'Глава 130');
  final book = UnifiedManga(title: 'Academy', entries: {
    'senkuro': const MangaEntry(source: 'senkuro', id: 'academy', title: 'Academy')});

  Future<LibraryStore> readTo(Chapter chapter, List<Chapter> known,
      {bool markRead = true}) async {
    final library = LibraryStore();
    await library.load();
    await library.setStatus(book, 'reading', preferredSource: 'senkuro');
    await library.savePosition(book, chapter, 'senkuro', pageIndex: 132, pageCount: 134);
    if (markRead) await library.markRead(book, chapter, 'senkuro');
    await library.recordLatestChapter(book, 'senkuro', known);
    return library;
  }

  test('newest known chapter read: title leaves Читаемое сейчас', () async {
    final library = await readTo(c129, [c128, c129]);
    expect(recentReadingBooks(library.items), isEmpty);
  });

  test('newest chapter opened but not finished: title stays', () async {
    final library = await readTo(c129, [c128, c129], markRead: false);
    expect(recentReadingBooks(library.items).single.lastChapterId, '129');
  });

  test('an older chapter read while newer exist: title stays', () async {
    final library = await readTo(c128, [c128, c129]);
    expect(recentReadingBooks(library.items).single.lastChapterId, '128');
  });

  test('a newer chapter becoming known brings the title back', () async {
    final library = await readTo(c129, [c128, c129]);
    await library.recordLatestChapter(book, 'senkuro', [c128, c129, c130]);
    expect(recentReadingBooks(library.items).single.lastChapterId, '129');
  });

  test('unknown latest chapter keeps the title visible', () async {
    final library = await readTo(c129, const []);
    expect(recentReadingBooks(library.items), hasLength(1));
  });

  test('hiding is display-only: progress and read markers are untouched', () async {
    final library = await readTo(c129, [c128, c129]);
    final reopened = LibraryStore();
    await reopened.load();
    final saved = reopened.get(book)!;
    expect(saved.lastReading!.chapterId, '129');
    expect(saved.lastPageIndex, 132);
    expect(reopened.isChapterRead(book, c129, 'senkuro'), isTrue);
    expect(library.items, hasLength(1));
  });
}

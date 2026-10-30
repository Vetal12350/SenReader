import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class _SequentialSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(
    source: 'senkuro', id: 'series', title: 'Последовательное чтение');
  final chapters = const [
    Chapter(id: '3', name: 'Глава 3 (т. 1)'),
    Chapter(id: '2', name: 'Глава 2 (т. 1)'),
    Chapter(id: '1', name: 'Глава 1 (т. 1)'),
  ];
  final List<String> requested = [];
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String q) => popular();
  @override Future<MangaDetail> detail(MangaEntry e) async =>
    MangaDetail(entry: e, chapters: chapters);
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    requested.add(chapter.id);
    // Real images are not loaded by the network-disabled Flutter test runner;
    // the reader's image error tiles provide deterministic item heights.
    final count = chapter.id == '1' ? 7 : 5;
    return List.generate(count,
      (i) => PageImage('https://invalid.example/${chapter.id}/$i.png'));
  }
  UnifiedManga get book => UnifiedManga(
    title: entry.title, entries: {key: entry});
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('next chapter loads inline without chapter-picker or navigation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _SequentialSource();
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: source.book, chapter: source.chapters.last,
      sourceKey: source.key, repository: CatalogRepository(
        sources: {source.key: source}), library: library,
      chapters: source.chapters,
    )));
    await tester.pumpAndSettle();
    expect(source.requested, ['1']);
    expect(find.byType(ReaderPage), findsOneWidget);

    // Scroll near the end, triggering a lazy fetch from the same source.
    for (var i = 0; i < 4 && !source.requested.contains('2'); i++) {
      await tester.drag(find.byType(ScrollablePositionedList),
        const Offset(0, -460));
      await tester.pumpAndSettle();
    }
    expect(source.requested, contains('2'));
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);

    // Advance physically into chapter 2, not merely near its boundary.
    for (var i = 0; i < 5 && library.get(source.book)?.lastChapterId != '2'; i++) {
      await tester.drag(find.byType(ScrollablePositionedList),
        const Offset(0, -350));
      await tester.pump(const Duration(milliseconds: 900));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(library.get(source.book)?.lastChapterId, '2');
    expect(library.get(source.book)?.lastSource, source.key);
    // Saving a page is NOT a completed-chapter eye marker.
    expect(library.isChapterRead(source.book, source.chapters.last, source.key), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last chapter does not fetch nonexistent chapters', (tester) async {
    final source = _SequentialSource();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: source.book, chapter: source.chapters.first,
      sourceKey: source.key, repository: CatalogRepository(
        sources: {source.key: source}), library: LibraryStore(),
      chapters: source.chapters,
    )));
    await tester.pumpAndSettle();
    expect(source.requested, ['3']);
    await tester.drag(find.byType(ScrollablePositionedList),
      const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(source.requested, ['3']);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';

class _LongWebtoonSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(source: 'senkuro', id: 'long-webtoon',
      title: 'Длинный вебтун');
  final chapters = [
    for (var n = 252; n >= 1; n--)
      Chapter(id: '$n', name: 'Глава $n'),
  ];
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String query) async => [entry];
  @override Future<MangaDetail> detail(MangaEntry e) async =>
      MangaDetail(entry: entry, chapters: chapters);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [
    for (var i = 0; i < 12; i++)
      PageImage('https://invalid.example/${chapter.id}/$i.png'),
  ];
  UnifiedManga get book =>
      UnifiedManga(title: entry.title, entries: {key: entry});
}

Future<void> _openControls(WidgetTester tester) async {
  await tester.tapAt(const Offset(160, 350));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('chapter picker starts near chapter 42, not newest chapter 252',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _LongWebtoonSource();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: source.book, chapter: source.chapters[210],
      chapters: source.chapters, sourceKey: source.key,
      library: LibraryStore(),
      repository: CatalogRepository(sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    await _openControls(tester);
    await tester.tap(find.byTooltip('Список глав'));
    await tester.pumpAndSettle();
    final picker = find.byKey(const Key('reader-chapter-picker'));
    expect(picker, findsOneWidget);
    final list = tester.widget<ScrollablePositionedList>(picker);
    expect(list.initialScrollIndex, 210);
    expect(find.byKey(const Key('reader-chapter-42')), findsOneWidget);
    expect(find.byKey(const Key('reader-chapter-43')), findsOneWidget);
    expect(find.byKey(const Key('reader-chapter-252')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('autoscroll moves a few pixels, not a whole image per tick',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _LongWebtoonSource();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: source.book, chapter: source.chapters.last,
      chapters: source.chapters, sourceKey: source.key,
      library: LibraryStore(),
      repository: CatalogRepository(sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    await _openControls(tester);
    final reader = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList));
    expect(reader.scrollOffsetController, isNotNull);
    // Observe actual movement of the first image error tile. No dependency
    // on package-private position listeners.
    final firstImage = find.text('Страница 1 не загрузилась');
    expect(firstImage, findsOneWidget);
    final before = tester.getTopLeft(firstImage).dy;
    await tester.tap(find.byTooltip('Автопрокрутка'));
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
    final now = tester.getTopLeft(firstImage).dy;
    expect(now, lessThan(before));
    // At 5 seconds per viewport, 640ms should not skip the first image.
    expect(now, greaterThan(before - 400));
    expect(find.byTooltip('Остановить автопрокрутку'), findsOneWidget);
    await tester.tap(find.byTooltip('Остановить автопрокрутку'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Автопрокрутка'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

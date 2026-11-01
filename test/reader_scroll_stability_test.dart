import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';

class _ImageSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(
    source: 'senkuro', id: 'geometry', title: 'Reader geometry');
  final chapter = const Chapter(id: '1', name: 'Глава 1');
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String query) async => [entry];
  @override Future<MangaDetail> detail(MangaEntry manga) async =>
      MangaDetail(entry: manga, chapters: [chapter]);
  @override Future<List<PageImage>> pages(Chapter ch) async => [
    for (var i = 0; i < 6; i++)
      PageImage('https://invalid.example/$i.png'),
  ];
  UnifiedManga get book =>
      UnifiedManga(title: entry.title, entries: {key: entry});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('decoded width matches device pixels with a 1600px maximum', () {
    expect(readerDecodeWidth(400, 3), 1200);
    expect(readerDecodeWidth(448, 4), 1600);
    expect(readerDecodeWidth(360, 1), 360);
    expect(readerDecodeWidth(0, 1), 1);
  });

  test('upcoming webtoon image reserves its actual aspect-ratio height', () {
    // A 360-pixel viewport with a long strip must not reserve a tiny 540px
    // placeholder and subsequently jump to a 3600px rendered image.
    expect(readerLogicalImageHeight(360, 1000, 10000), 3600);
    expect(readerLogicalImageHeight(400, 1200, 2400), 800);
    // The downsampled decoder preserves the ratio of a high-density image.
    expect(readerLogicalImageHeight(360, 1600, 12800), 2880);
    expect(readerLogicalImageHeight(400, 0, 1000), isNull);
    expect(readerLogicalImageHeight(-1, 1000, 1000), isNull);
    expect(readerLogicalImageHeight(360, 1, 1000000), isNull);
  });

  testWidgets('reader image uses bounded decoded provider during scrolling',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _ImageSource();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: source.book, chapter: source.chapter,
      chapters: [source.chapter], sourceKey: source.key,
      library: LibraryStore(), repository: CatalogRepository(
        sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    final reader = find.byType(ScrollablePositionedList);
    expect(reader, findsOneWidget);
    final images = tester.widgetList<Image>(
      find.descendant(of: reader, matching: find.byType(Image))).toList();
    expect(images, isNotEmpty);
    expect(images.every((image) => image.image is ResizeImage), isTrue);
    // Widget-test DPR is not tied to setSurfaceSize. Any on-screen reader
    // image must be bounded without relying on a fixed test-device DPI.
    expect((images.first.image as ResizeImage).width,
      inInclusiveRange(1, 1600));
    await tester.drag(reader, const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

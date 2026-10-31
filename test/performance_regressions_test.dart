import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/detail_page.dart';
import 'package:senreader/ui/widgets.dart';

class _LongSeriesSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(
      source: 'senkuro', id: 'long-series', title: 'Большая серия');
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String query) async => [entry];
  @override Future<MangaDetail> detail(MangaEntry record) async =>
      MangaDetail(entry: record, chapters: [
        for (var chapter = 800; chapter >= 1; chapter--)
          Chapter(id: '$chapter', name: 'Глава $chapter'),
      ]);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('800 chapters are virtualized rather than built up-front',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _LongSeriesSource();
    final library = LibraryStore();
    final book = UnifiedManga(
        title: source.entry.title, entries: {source.key: source.entry});
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, library: library,
      repository: CatalogRepository(sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(find.byType(ListTile).evaluate().length, lessThan(35));
    await tester.drag(find.byType(ListView).first, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(35));
    expect(tester.takeException(), isNull);
  });

  testWidgets('covers use bounded decoded image sizes', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SizedBox(
      width: 116, height: 160,
      child: CoverImage('https://example.invalid/cover.jpg'),
    )));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/detail_page.dart';

class _TransientSource implements MangaSource {
  int calls = 0;
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final MangaEntry entry = const MangaEntry(
    source: 'senkuro', id: 'test', title: 'Тестовая манга');
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
  @override Future<MangaDetail> detail(MangaEntry record) async {
    calls++;
    if (calls == 1) {
      throw SourceException('Senkuro: HTTP 429. Возможно, доступ ограничен.');
    }
    return MangaDetail(entry: record, chapters: const [
      Chapter(id: 'ch1', name: 'Глава 1'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('detail retries a rate limit silently without leaving the page',
      (tester) async {
    final source = _TransientSource();
    final book = UnifiedManga(title: source.entry.title,
        entries: {'senkuro': source.entry});
    final library = LibraryStore();
    await library.add(book); // Saved books previously could not fall back.
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, repository: CatalogRepository(sources: {'senkuro': source}),
      library: library,
    )));
    await tester.pump();
    expect(find.textContaining('HTTP 429'), findsNothing);
    expect(find.text('Повторить'), findsNothing);
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(source.calls, 2);
    await tester.scrollUntilVisible(find.text('Глава 1'), 200,
      scrollable: find.byType(Scrollable).first);
    expect(find.text('Глава 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

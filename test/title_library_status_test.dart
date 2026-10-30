import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/detail_page.dart';

class _TitleSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(
    source: 'senkuro', id: 'title', title: 'Пример манги');
  @override Future<List<MangaEntry>> popular() async => [entry];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry manga) async =>
    MangaDetail(entry: manga, chapters: const []);
  @override Future<List<PageImage>> pages(Chapter chapter) async => const [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('title has only compact source action, library management stays in status menu', (tester) async {
    final source = _TitleSource();
    final book = UnifiedManga(title: source.entry.title,
      entries: {source.key: source.entry});
    final library = LibraryStore();
    await library.add(book);
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, library: library,
      repository: CatalogRepository(sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.actions, hasLength(1));
    expect(find.byTooltip('Сменить источник'), findsOneWidget);
    expect(find.byTooltip('Добавить в библиотеку'), findsNothing);
    await tester.tap(find.byTooltip('Статус произведения'));
    await tester.pumpAndSettle();
    expect(find.text('Убрать из библиотеки'), findsOneWidget);
    await tester.tap(find.text('Убрать из библиотеки'));
    await tester.pumpAndSettle();
    expect(library.has(book), false);
    expect(tester.takeException(), isNull);
  });
}

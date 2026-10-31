import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/chapter_identity.dart';
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

class _SearchableTitleSource extends _TitleSource {
  @override Future<MangaDetail> detail(MangaEntry record) async =>
    MangaDetail(entry: record, chapters: const [
      Chapter(id: '1', name: 'Глава 1 (т. 1)'),
      Chapter(id: '2', name: 'Глава 2 (т. 1)'),
      Chapter(id: '3', name: 'Глава 3 (т. 1)'),
    ], description: 'Это краткое описание произведения.');
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
  testWidgets('Senkuro-style title has read button, source and searchable chapters',
      (tester) async {
    final source = _SearchableTitleSource();
    final book = UnifiedManga(title: source.entry.title,
      entries: {source.key: source.entry});
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, library: LibraryStore(),
      repository: CatalogRepository(sources: {source.key: source}),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('title-read-button')), findsOneWidget);
    expect(find.byTooltip('Сменить источник'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chapter-search')),
      160, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const Key('chapter-search')), '3');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Глава 3 (т. 1)'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Глава 1 (т. 1)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}

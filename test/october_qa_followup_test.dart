import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/main.dart';
import 'package:senreader/ui/detail_page.dart';
import 'package:senreader/ui/widgets.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

class _TestSource implements MangaSource {
  _TestSource(this.key, this.name);
  @override final String key;
  @override final String name;
  @override Map<String, String> get imageHeaders => const {};
  MangaEntry get entry => MangaEntry(source: key, id: 'id-$key',
      title: 'Ищу $name');
  @override Future<List<MangaEntry>> search(String query) async => [entry];
  @override Future<List<MangaEntry>> popular() async =>
      List.generate(15, (i) => MangaEntry(source: key, id: '$key-$i',
          title: '$name $i'));
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
      MangaDetail(entry: entry,
        chapters: const [Chapter(id: '103', name: 'Глава 103')]);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('manual eye enrolls in reading, automatic opening does not', () async {
    final source = _TestSource('senkuro', 'Senkuro');
    final book = UnifiedManga(title: source.entry.title,
        entries: {source.key: source.entry});
    final chapter = const Chapter(id: '103', name: 'Глава 103');
    final library = LibraryStore();
    await library.markRead(book, chapter, source.key);
    expect(library.get(book)?.status, 'viewed');
    expect(readingStatusBadge(library.get(book)), isNull);
    await library.markRead(book, chapter, source.key, userInitiated: true);
    expect(library.get(book)?.status, 'reading');
    expect(library.get(book)?.lastChapter, isEmpty);
    expect(readingStatusBadge(library.get(book)), 'Читаю · 103 гл.');
    await library.savePosition(book, chapter, source.key,
        pageIndex: 3, pageCount: 12);
    expect(library.get(book)?.lastPageIndex, 3);
    expect(readingStatusBadge(library.get(book)), 'Читаю · 103 гл.');
    await library.load();
    expect(library.get(book)?.status, 'reading');
    expect(library.get(book)?.lastPageIndex, 3);
  });

  testWidgets('detail shows selected category without chapter search',
      (tester) async {
    final source = _TestSource('senkuro', 'Senkuro');
    final book = UnifiedManga(title: source.entry.title,
        entries: {source.key: source.entry});
    final library = LibraryStore();
    await library.setStatus(book, 'completed', preferredSource: source.key);
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, repository: CatalogRepository(sources: {source.key: source}),
      library: library,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Прочитано'), findsOneWidget);
    expect(find.text('Добавить в список'), findsNothing);
    expect(find.byKey(const Key('chapter-search')), findsNothing);
  });

  testWidgets('global search stays fixed, catalog filters reset on exit',
      (tester) async {
    final sources = {
      'senkuro': _TestSource('senkuro', 'Senkuro'),
      'remanga': _TestSource('remanga', 'ReManga'),
      'readmanga': _TestSource('readmanga', 'ReadManga'),
    };
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: sources),
      library: library,
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каталог').last);
    await tester.pumpAndSettle();
    const searchKey = Key('catalog-search');
    expect(find.byKey(searchKey), findsOneWidget);
    await tester.enterText(find.byKey(searchKey), 'demo');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Ищу Senkuro'), findsOneWidget);
    expect(find.text('Ищу ReManga'), findsOneWidget);
    expect(find.text('Ищу ReadManga'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byKey(searchKey), findsOneWidget);
    await tester.tap(find.text('Главная').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каталог').last);
    await tester.pumpAndSettle();
    expect(find.byKey(searchKey), findsOneWidget);
    expect(find.text('Ищу ReManga'), findsNothing);
    expect(find.text('По популярности'), findsOneWidget);
  });
}

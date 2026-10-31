import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/main.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

class _TestCatalogSource implements MangaSource {
  _TestCatalogSource(this.key, this.title, [this.tags = const []]);
  @override final String key;
  final String title;
  final List<String> tags;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  @override Future<List<MangaEntry>> popular() async => [
    MangaEntry(source: key, id: key, title: title, tags: tags),
  ];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
    MangaDetail(entry: entry, chapters: const []);
  @override Future<List<PageImage>> pages(Chapter chapter) async => const [];
}

class _SearchCatalogSource extends _TestCatalogSource {
  _SearchCatalogSource() : super('senkuro', 'Популярная манга');
  @override Future<List<MangaEntry>> search(String query) async => [
    const MangaEntry(source: 'senkuro', id: 'dungeon',
        title: 'Подземная одиссея'),
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('catalog shows only Senkuro; alternate sources remain outside catalog', (tester) async {
    final sources = <String, MangaSource>{
      'senkuro': _TestCatalogSource('senkuro', 'Альфа'),
      'readmanga': _TestCatalogSource('readmanga', 'Янтарь'),
    };
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: sources), library: LibraryStore(),
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каталог').first);
    await tester.pumpAndSettle();
    expect(find.text('Альфа'), findsOneWidget);
    expect(find.text('Янтарь'), findsNothing);
    expect(find.byTooltip('Фильтр по источнику'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog no longer has alphabetical title sorting', (tester) async {
    final source = _TestCatalogSource('senkuro', 'Альфа');
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: {source.key: source}),
      library: LibraryStore(),
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каталог').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Сортировка каталога'), findsNothing);
    expect(find.byKey(const Key('catalog-tag-filters')), findsOneWidget);
  });

  testWidgets('catalog search never destroys home popular results', (tester) async {
    final source = _SearchCatalogSource();
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: {source.key: source}),
      library: LibraryStore(),
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Популярная манга'), findsWidgets);
    await tester.tap(find.text('Каталог').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'подземная');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Подземная одиссея'), findsOneWidget);
    await tester.tap(find.text('Главная').last);
    await tester.pumpAndSettle();
    expect(find.text('Популярная манга'), findsWidgets);
    expect(find.text('Подземная одиссея'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog tag filters select only source-backed matching entries',
      (tester) async {
    final sources = <String, MangaSource>{
      'senkuro': _TestCatalogSource('senkuro', 'Космос', ['Фантастика']),
      'readmanga': _TestCatalogSource('readmanga', 'Романтика'),
    };
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: sources), library: LibraryStore(),
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каталог').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('catalog-tag-filters')));
    await tester.pumpAndSettle();
    // The larger Senkuro filter sheet is lazily built; scroll its own list.
    for (var attempt = 0;
         attempt < 6 && find.text('Фантастика').evaluate().isEmpty;
         attempt++) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(find.text('Фантастика'), findsOneWidget);
    await tester.tap(find.text('Фантастика'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Показать'));
    await tester.pumpAndSettle();
    expect(find.text('Космос'), findsOneWidget);
    expect(find.text('Романтика'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home does not show mixed-source general catalog tiles', (tester) async {
    final sources = <String, MangaSource>{
      'senkuro': _TestCatalogSource('senkuro', 'Сенкуро тайтл'),
      'readmanga': _TestCatalogSource('readmanga', 'Другой источник'),
    };
    await tester.pumpWidget(MaterialApp(home: MainShell(
      repository: CatalogRepository(sources: sources), library: LibraryStore(),
      alerts: ChapterAlertController(
        preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Сенкуро тайтл'), findsWidgets);
    expect(find.text('Другой источник'), findsNothing);
    expect(find.text('Общий каталог'), findsNothing);
    await tester.tap(find.text('Каталог').first);
    await tester.pumpAndSettle();
    expect(find.text('Другой источник'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}

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
  _TestCatalogSource(this.key, this.title);
  @override final String key;
  final String title;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  @override Future<List<MangaEntry>> popular() async => [
    MangaEntry(source: key, id: key, title: title),
  ];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
    MangaDetail(entry: entry, chapters: const []);
  @override Future<List<PageImage>> pages(Chapter chapter) async => const [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('catalog source filter excludes other sources and can be reset', (tester) async {
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
    expect(find.text('Янтарь'), findsOneWidget);

    await tester.tap(find.byTooltip('Фильтр по источнику'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ReadManga').last);
    await tester.pumpAndSettle();
    expect(find.text('Янтарь'), findsOneWidget);
    expect(find.text('Альфа'), findsNothing);

    await tester.tap(find.byTooltip('Фильтр по источнику'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Все источники').last);
    await tester.pumpAndSettle();
    expect(find.text('Альфа'), findsOneWidget);
    expect(find.text('Янтарь'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog local title sorting changes visual order', (tester) async {
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
    await tester.tap(find.byTooltip('Сортировка каталога'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Название Я-А').last);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Янтарь')).dx,
      lessThan(tester.getTopLeft(find.text('Альфа')).dx));
    expect(tester.takeException(), isNull);
  });
}

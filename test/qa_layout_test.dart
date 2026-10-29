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
import 'package:senreader/ui/reader_page.dart';
import 'package:senreader/ui/chapter_notifications_panel.dart';
import 'package:senreader/ui/widgets.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

class LayoutSource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  final entry = const MangaEntry(source: 'senkuro', id: 'series',
    title: 'Очень длинное название произведения для проверки переноса строк');
  final chapters = const [
    Chapter(id: '3', name: 'Глава 3 (т. 2)'),
    Chapter(id: '2', name: 'Глава 2 (т. 2)'),
    Chapter(id: '1', name: 'Глава 10 (т. 1)'),
  ];
  @override Future<List<MangaEntry>> popular() async => [entry, entry, entry];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry record) async =>
      MangaDetail(entry: record, chapters: chapters);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
  UnifiedManga get book => UnifiedManga(title: entry.title, entries: {key: entry});
}

class ReaderImageSource extends LayoutSource {
  // Flutter's widget-test HTTP client returns 400 without contacting this URL.
  @override Future<List<PageImage>> pages(Chapter chapter) async =>
      [const PageImage('https://fixture.invalid/page.png')];
}

Widget scaledApp(Widget child, double scale) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!),
  home: child,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [320.0, 360.0, 393.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('home carousel at width=$width text scale=$scale has no overflow', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final source = LayoutSource();
        final library = LibraryStore();
        await library.savePosition(source.book, source.chapters[1], source.key,
            pageIndex: 3, pageCount: 10);
        await tester.pumpWidget(scaledApp(MainShell(
          repository: CatalogRepository(sources: {source.key: source}), library: library,
          alerts: ChapterAlertController(preferences: MemoryAlertPreferences()..shown = true),
        ), scale));
        await tester.pumpAndSettle();
        expect(find.byType(MangaTile), findsWidgets);
        expect(tester.takeException(), isNull);
        final horizontal = find.byWidgetPredicate((widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal).first;
        await tester.drag(horizontal, const Offset(-140, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Продолжить чтение'), 200,
          scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('library has bookmarks/filters only; Settings owns notification actions', (tester) async {
    final source = LayoutSource();
    final library = LibraryStore();
    await library.add(source.book);
    await tester.pumpWidget(scaledApp(MainShell(
      repository: CatalogRepository(sources: {source.key: source}), library: library,
      alerts: ChapterAlertController(preferences: MemoryAlertPreferences()..shown = true),
    ), 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Библиотека'));
    await tester.pumpAndSettle();
    expect(find.byType(MangaTile), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNWidgets(4));
    expect(find.byType(ChapterNotificationsPanel), findsNothing);
    expect(find.text('Проверить новые главы'), findsNothing);
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterNotificationsPanel), findsOneWidget);
    expect(find.text('Проверить новые главы'), findsOneWidget);
    expect(find.byType(DropdownButton<int>), findsNothing);
    await tester.tap(find.text('Проверить новые главы'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Проверено произведений: 1.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('left eye marks older chapters without opening reader; unread reverses only target', (tester) async {
    final source = LayoutSource();
    final library = LibraryStore();
    await library.add(source.book);
    await tester.pumpWidget(scaledApp(DetailPage(book: source.book,
      repository: CatalogRepository(sources: {source.key: source}), library: library), 1));
    await tester.pumpAndSettle();
    final row = find.widgetWithText(ListTile, source.chapters[1].name);
    await tester.scrollUntilVisible(row, 220, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: row, matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsNothing);
    expect(library.isChapterRead(source.book, source.chapters[1], source.key), true);
    expect(library.isChapterRead(source.book, source.chapters[2], source.key), true);
    expect(library.isChapterRead(source.book, source.chapters[0], source.key), false);
    expect(find.descendant(of: row, matching: find.byIcon(Icons.visibility_outlined)), findsOneWidget);
    await tester.tap(find.descendant(of: row, matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
    expect(library.isChapterRead(source.book, source.chapters[1], source.key), false);
    expect(library.isChapterRead(source.book, source.chapters[2], source.key), true);
    expect(find.descendant(of: row, matching: find.byIcon(Icons.visibility_off_outlined)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader bottom toolbar navigates available chapters and stays outside content', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = LayoutSource();
    final library = LibraryStore();
    await tester.pumpWidget(scaledApp(ReaderPage(book: source.book,
      chapter: source.chapters[1], sourceKey: source.key,
      chapters: source.chapters, library: library,
      repository: CatalogRepository(sources: {source.key: source})), 2));
    await tester.pumpAndSettle();
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.actions, isNull);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.bottomNavigationBar, isNotNull);
    expect(scaffold.extendBody, false);
    expect(find.byType(SafeArea), findsWidgets);
    await tester.tap(find.byTooltip('Список глав'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));
    await tester.tap(find.widgetWithText(ListTile, source.chapters[0].name));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, source.chapters[0].name), findsOneWidget);
    final next = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next_rounded));
    expect(next.onPressed, isNull);
    await tester.tap(find.byTooltip('Предыдущая глава'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, source.chapters[1].name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader bottom eye completes available older chapters without changing resume', (tester) async {
    final source = ReaderImageSource();
    final library = LibraryStore();
    await library.savePosition(source.book, source.chapters[1], source.key,
      pageIndex: 0, pageCount: 1);
    await tester.pumpWidget(scaledApp(ReaderPage(book: source.book,
      chapter: source.chapters[1], sourceKey: source.key, chapters: source.chapters,
      library: library, repository: CatalogRepository(sources: {source.key: source})), 1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.visibility_off_outlined));
    await tester.pumpAndSettle();
    expect(library.isChapterRead(source.book, source.chapters[1], source.key), true);
    expect(library.isChapterRead(source.book, source.chapters[2], source.key), true);
    expect(library.isChapterRead(source.book, source.chapters[0], source.key), false);
    expect(library.items.single.lastChapterId, '2');
    expect(library.items.single.lastPageIndex, 0);
    expect(find.widgetWithIcon(IconButton, Icons.visibility_outlined), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(library.isChapterRead(source.book, source.chapters[1], source.key), false);
    expect(library.isChapterRead(source.book, source.chapters[2], source.key), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

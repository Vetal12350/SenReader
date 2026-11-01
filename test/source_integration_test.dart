import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/detail_page.dart';

class FixtureSource implements MangaSource {
  FixtureSource(this.key, {this.title = 'Example', this.readable = false, this.fails = false});
  @override final String key;
  final String title;
  final bool readable;
  final bool fails;
  int detailCalls = 0;
  Completer<MangaDetail>? pending;
  MangaEntry get entry => MangaEntry(source: key, id: key, title: title);
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  @override Future<List<MangaEntry>> popular() async {
    if (fails) throw SourceException('offline');
    return [entry];
  }
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry entry) async {
    detailCalls++;
    if (pending != null) return pending!.future;
    if (fails) throw SourceException('offline');
    return MangaDetail(entry: entry,
        chapters: readable ? [const Chapter(id: '1', name: 'Readable chapter')] : []);
  }
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
}


Future<void> revealInScrollable(WidgetTester tester, Finder finder,
    {bool towardsTop = false}) async {
  await tester.scrollUntilVisible(
    finder, towardsTop ? -250 : 250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}



void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default repository makes requests only to Senkuro and ReadManga', () {
    expect(CatalogRepository().sources.keys, ['senkuro', 'readmanga']);
    expect(CatalogRepository().sources.containsKey('remanga'), false);
  });

  test('catalog and search isolate failures and merge only exact normalized titles', () async {
    final sources = [FixtureSource('senkuro', fails: true),
      FixtureSource('readmanga'), FixtureSource('remanga', title: 'Example 2')];
    final repo = CatalogRepository(sources: {for (final source in sources) source.key: source});
    for (final query in ['', 'Example']) {
      final result = await repo.getCatalog(query: query);
      expect(result.books.length, 2);
      expect(result.warnings.single, contains('senkuro'));
    }
    final remanga = FixtureSource('remanga', title: 'EXAMPLE!');
    final exactRepo = CatalogRepository(sources: {'readmanga': sources[1], 'remanga': remanga});
    final result = await exactRepo.getCatalog();
    expect(result.books.single.entries.keys, ['readmanga', 'remanga']);
    final book = UnifiedManga(title: 'Example', entries: {'readmanga': sources[1].entry});
    expect((await repo.findOtherSources(book)).entries.keys, ['readmanga']);
    expect((await exactRepo.findOtherSources(book)).entries.keys, ['readmanga', 'remanga']);
  });


  testWidgets('legacy ReManga bookmark is preserved and replaced automatically',
      (tester) async {
    final old = const MangaEntry(
        source: 'remanga', id: 'old', title: 'Example');
    final legacy = UnifiedManga(title: 'Example', entries: {'remanga': old});
    final library = LibraryStore();
    await library.setStatus(legacy, 'reading', preferredSource: 'remanga');
    final senkuro = FixtureSource('senkuro', readable: true);
    final repo = CatalogRepository(sources: {'senkuro': senkuro});
    await tester.pumpWidget(MaterialApp(home: DetailPage(
        book: legacy, repository: repo, library: library)));
    await tester.pumpAndSettle();
    expect(library.items.single.entries.keys, contains('remanga'));
    expect(library.items.single.entries.keys, contains('senkuro'));
    expect(library.items.single.preferredSource, 'senkuro');
    await revealInScrollable(tester, find.text('Readable chapter'));
    expect(find.text('Readable chapter'), findsOneWidget);
    expect(find.byTooltip('Сменить источник'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network failure does not switch to a different translation', (tester) async {
    final sources = [FixtureSource('senkuro', fails: true),
      FixtureSource('readmanga', readable: true)];
    final repo = CatalogRepository(sources: {for (final s in sources) s.key: s});
    final book = UnifiedManga(title: 'Example',
      entries: {for (final s in sources) s.key: s.entry});
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, repository: repo, library: library)));
    await tester.pumpAndSettle();
    expect(sources.map((s) => s.detailCalls), [1, 0]);
    expect(find.byTooltip('Сменить источник'), findsNothing);
    expect(library.items, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all unavailable sources terminate without a loop', (tester) async {
    final sources = [FixtureSource('senkuro'), FixtureSource('readmanga'), FixtureSource('remanga', fails: true)];
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: UnifiedManga(title: 'Example', entries: {for (final s in sources) s.key: s.entry}),
      repository: CatalogRepository(sources: {for (final s in sources) s.key: s}), library: LibraryStore())));
    await tester.pumpAndSettle();
    expect(sources.map((s) => s.detailCalls), [1, 1, 1]);
    await revealInScrollable(tester,
        find.text('Главы временно недоступны. Попробуйте открыть их позже.'));
    expect(find.text('Повторить'), findsNothing);
  });

  testWidgets('late discovery retries only newly matched sources', (tester) async {
    final senkuro = FixtureSource('senkuro');
    final remanga = FixtureSource('remanga', readable: true);
    final unrelated = FixtureSource('readmanga', title: 'Example sequel', readable: true);
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: UnifiedManga(title: 'Example', entries: {'senkuro': senkuro.entry}),
      repository: CatalogRepository(sources: {'senkuro': senkuro, 'readmanga': unrelated, 'remanga': remanga}),
      library: LibraryStore())));
    await tester.pumpAndSettle();
    await revealInScrollable(tester, find.text('Readable chapter'));
    expect(find.text('Readable chapter'), findsOneWidget);
    expect(unrelated.detailCalls, 0);
    expect(senkuro.detailCalls, 1);
    expect(remanga.detailCalls, 1);
  });

  testWidgets('saved progress prevents automatic source switching after failure',
      (tester) async {
    final senkuro = FixtureSource('senkuro', fails: true);
    final readmanga = FixtureSource('readmanga', readable: true);
    final book = UnifiedManga(title: 'Example', entries: {
      'senkuro': senkuro.entry, 'readmanga': readmanga.entry,
    });
    final repo = CatalogRepository(sources: {
      'senkuro': senkuro, 'readmanga': readmanga,
    });
    final library = LibraryStore();
    await library.add(book);
    await library.savePosition(book, const Chapter(id: 'old', name: 'Глава 7'),
      'senkuro', pageIndex: 3, pageCount: 10);
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book, repository: repo, library: library)));
    await tester.pumpAndSettle();
    expect(senkuro.detailCalls, 1);
    expect(readmanga.detailCalls, 0);
    expect(library.items.single.preferredSource, 'senkuro');
    expect(library.items.single.lastChapter, 'Глава 7');
    expect(library.items.single.lastPageIndex, 3);
    expect(find.byTooltip('Сменить источник'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty initial source falls back automatically without manual choice',
      (tester) async {
    final senkuro = FixtureSource('senkuro');
    final readmanga = FixtureSource('readmanga', readable: true);
    final book = UnifiedManga(title: 'Example', entries: {
      'senkuro': senkuro.entry, 'readmanga': readmanga.entry,
    });
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: book,
      repository: CatalogRepository(sources: {
        'senkuro': senkuro, 'readmanga': readmanga,
      }), library: LibraryStore())));
    await tester.pumpAndSettle();
    expect(senkuro.detailCalls, greaterThan(0));
    expect(readmanga.detailCalls, greaterThan(0));
    await revealInScrollable(tester, find.text('Readable chapter'));
    expect(find.text('Readable chapter'), findsOneWidget);
    expect(find.byTooltip('Сменить источник'), findsNothing);
  });

  test('v1 bookmarks and progress survive adding ReManga and reload', () async {
    const legacy = '[{"title":"Example","entries":{'
        '"senkuro":{"source":"senkuro","id":"old","title":"Example","coverUrl":""},'
        '"readmanga":{"source":"readmanga","id":"/old","title":"Example","coverUrl":""}'
        '},"lastChapter":"Глава 7","lastSource":"readmanga"}]';
    SharedPreferences.setMockInitialValues({LibraryStore.storageKey: legacy});
    final library = LibraryStore();
    await library.load();
    final book = library.items.single.toUnified();
    book.entries['remanga'] = const MangaEntry(source: 'remanga', id: 'sample', title: 'Example');
    await library.add(book);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.items.single.entries.keys, ['senkuro', 'readmanga', 'remanga']);
    expect(restored.items.single.lastChapter, 'Глава 7');
    expect(restored.items.single.lastSource, 'readmanga');
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString('senreader.library.v1')!) as List;
    expect((raw.single as Map).keys.toSet(), containsAll(
      {'title', 'entries', 'lastChapter', 'lastSource',
       'seenChapterKeys', 'initializedSources'}));
  });
}

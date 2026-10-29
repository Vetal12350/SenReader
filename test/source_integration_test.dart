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

Future<void> selectSource(WidgetTester tester, String source) async {
  await tester.tap(find.byTooltip('Сменить источник'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(source).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default repository configures exactly three sources', () {
    expect(CatalogRepository().sources.keys, ['senkuro', 'readmanga', 'remanga']);
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

  testWidgets('unsaved fallback tries each source once; manual picker stops fallback', (tester) async {
    final sources = [FixtureSource('senkuro', fails: true),
      FixtureSource('readmanga'), FixtureSource('remanga', readable: true)];
    final repo = CatalogRepository(sources: {for (final s in sources) s.key: s});
    final book = UnifiedManga(title: 'Example', entries: {for (final s in sources) s.key: s.entry});
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: DetailPage(book: book, repository: repo, library: library)));
    await tester.pumpAndSettle();
    expect(sources.map((s) => s.detailCalls), [1, 1, 1]);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
    await revealInScrollable(tester, find.text('Readable chapter'));
    expect(find.text('Readable chapter'), findsOneWidget);
    await selectSource(tester, 'readmanga');
    expect(sources[1].detailCalls, 2);
    expect(sources[2].detailCalls, 1);
    expect(library.items, isEmpty);
  });

  testWidgets('all unavailable sources terminate without a loop', (tester) async {
    final sources = [FixtureSource('senkuro'), FixtureSource('readmanga'), FixtureSource('remanga', fails: true)];
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: UnifiedManga(title: 'Example', entries: {for (final s in sources) s.key: s.entry}),
      repository: CatalogRepository(sources: {for (final s in sources) s.key: s}), library: LibraryStore())));
    await tester.pumpAndSettle();
    expect(sources.map((s) => s.detailCalls), [1, 1, 1]);
    await revealInScrollable(tester, find.text('Повторить'));
    expect(find.text('Повторить'), findsOneWidget);
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

  testWidgets('saved source failure never falls back; explicit choice survives reopening', (tester) async {
    final senkuro = FixtureSource('senkuro', fails: true);
    final remanga = FixtureSource('remanga', readable: true);
    final book = UnifiedManga(title: 'Example', entries: {
      'senkuro': senkuro.entry, 'remanga': remanga.entry,
    });
    final repo = CatalogRepository(sources: {'senkuro': senkuro, 'remanga': remanga});
    final library = LibraryStore();
    await library.add(book);
    await tester.pumpWidget(MaterialApp(home: DetailPage(book: book,
      repository: repo, library: library)));
    await tester.pumpAndSettle();
    expect(senkuro.detailCalls, 1);
    expect(remanga.detailCalls, 0);
    expect(library.items.single.preferredSource, 'senkuro');
    await selectSource(tester, 'remanga');
    expect(library.items.single.preferredSource, 'remanga');
    final restored = LibraryStore();
    await restored.load();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: DetailPage(book: book,
      repository: repo, library: restored)));
    await tester.pumpAndSettle();
    expect(senkuro.detailCalls, 1);
    expect(remanga.detailCalls, 2);
    expect(restored.items.single.entries.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale detail response cannot overwrite explicit source selection', (tester) async {
    final senkuro = FixtureSource('senkuro')..pending = Completer<MangaDetail>();
    final remanga = FixtureSource('remanga', readable: true);
    await tester.pumpWidget(MaterialApp(home: DetailPage(
      book: UnifiedManga(title: 'Example', entries: {'senkuro': senkuro.entry, 'remanga': remanga.entry}),
      repository: CatalogRepository(sources: {'senkuro': senkuro, 'remanga': remanga}), library: LibraryStore())));
    await tester.pump();
    await selectSource(tester, 'remanga');
    senkuro.pending!.complete(MangaDetail(entry: senkuro.entry, chapters: []));
    await tester.pumpAndSettle();
    await revealInScrollable(tester, find.text('Readable chapter'));
    expect(find.text('Readable chapter'), findsOneWidget);
    expect(remanga.detailCalls, 1);
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

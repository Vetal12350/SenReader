import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/chapter_updates.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/core/title_matching.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/chapter_updates_page.dart';
import 'package:senreader/ui/source_link_page.dart';
import 'package:senreader/ui/reader_page.dart';

Chapter ch(String number, {String id = 'local', String volume = '1', String subtitle = '', bool readable = true}) =>
  Chapter(id: id, name: 'Глава $number: $subtitle', volume: volume, number: number, readable: readable);
ChapterRelease release(String number, {String source = 'senkuro', String id = 'local', String subtitle = ''}) =>
  ChapterRelease(source: source, chapter: ch(number, id: id, subtitle: subtitle));

class UpdateFixture implements MangaSource {
  UpdateFixture(this.key, {this.title = 'Example'});
  @override final String key;
  final String title;
  List<Chapter> chapters = [];
  bool offline = false;
  final Set<String> blocked = {};
  final Set<String> empty = {};
  final List<String> pageCalls = [];
  Completer<List<PageImage>>? pendingPages;
  final requestedPages = Completer<void>();
  List<MangaEntry>? searchResults;
  MangaEntry get entry => MangaEntry(source: key, id: key, title: title);
  @override String get name => key;
  @override Map<String, String> get imageHeaders => {};
  @override Future<List<MangaEntry>> popular() async => searchResults ?? [entry];
  @override Future<List<MangaEntry>> search(String query) => popular();
  @override Future<MangaDetail> detail(MangaEntry entry) async {
    if (offline) throw SourceException('HTTP 403');
    return MangaDetail(entry: entry, chapters: chapters);
  }
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    pageCalls.add(chapter.id);
    if (!requestedPages.isCompleted) requestedPages.complete();
    if (blocked.contains(chapter.id)) throw SourceException('HTTP 403 / locked');
    if (empty.contains(chapter.id)) return [];
    if (pendingPages != null) return pendingPages!.future;
    return [const PageImage('https://cdn.example/page.jpg')];
  }
}

UnifiedManga bookFor(List<UpdateFixture> sources, {String title = 'Example'}) =>
  UnifiedManga(title: title, entries: {for (final s in sources) s.key: s.entry});
ChapterChecker checkerFor(List<UpdateFixture> sources) =>
  ChapterChecker({for (final s in sources) s.key: s});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('baseline suppresses all historical chapters; later one new chapter is idempotent', () {
    final baseline = reduceChapterCheck(ChapterUpdateState(), [release('1'), release('2')], successfulSources: 1);
    expect(baseline.state.initialized, isTrue);
    expect(baseline.newChapters, isEmpty);
    expect(baseline.state.notified, isEmpty);
    final next = reduceChapterCheck(baseline.state, [release('1'), release('2'), release('3')], successfulSources: 1);
    expect(next.newChapters.single.key, 'v1:c3');
    expect(next.state.notified, {'v1:c3'});
    final duplicate = reduceChapterCheck(next.state, [release('3', source: 'remanga', id: 'other', subtitle: 'Changed')], successfulSources: 1);
    expect(duplicate.newChapters, isEmpty);
    expect(duplicate.state.inbox['v1:c3']!.source, 'senkuro');
  });

  test('exact decimal and volume keys ignore subtitles and source IDs', () {
    expect(canonicalChapterKey(ch('0007.1200', volume: '01')), 'v1:c7.12');
    expect(canonicalChapterKey(ch('7.120000000000000001')), 'v1:c7.120000000000000001');
    expect(canonicalChapterKey(ch('7.12', id: 'other', subtitle: 'Changed')), 'v1:c7.12');
    expect(canonicalChapterKey(ch('7.12', volume: '2')), 'v2:c7.12');
    expect(canonicalChapterKey(ch('7,5')), 'v1:c7.5');
    expect(canonicalChapterKey(const Chapter(id: 'random', name: 'Special 12th anniversary')), isNull);
    expect(canonicalChapterKey(const Chapter(id: 'old', name: 'Глава 7.5: Renamed')), 'v0:c7.5');
    expect(canonicalChapterKey(const Chapter(id: '/vol2/7', name: '2 - 7.50: Subtitle')), 'v2:c7.5');
    expect(canonicalChapterKey(ch('invalid')), isNull);
    final state = ChapterUpdateState(initialized: true);
    final result = reduceChapterCheck(state, [release('7.1'), release('7.10', id: 'copy'), release('7.11')], successfulSources: 1);
    expect(result.newChapters.map((e) => e.key), ['v1:c7.1', 'v1:c7.11']);
  });

  test('all-source failure leaves baseline uninitialized and later success baselines', () async {
    final source = UpdateFixture('senkuro')..offline = true;
    final checker = checkerFor([source]);
    final failed = await checker.check(bookFor([source]).entries, ChapterUpdateState());
    expect(failed.state.initialized, isFalse);
    expect(failed.warnings.single, contains('403'));
    source.offline = false;
    source.chapters = [ch('10')];
    final baseline = await checker.check(bookFor([source]).entries, failed.state);
    expect(baseline.newChapters, isEmpty);
    expect(baseline.state.seen, {'v1:c10'});
  });

  test('a listing with only 403/empty readers waits for its first readable baseline', () async {
    final source = UpdateFixture('senkuro')..chapters = [ch('1', id: 'blocked'), ch('2', id: 'empty')];
    source.blocked.add('blocked');
    source.empty.add('empty');
    final checker = checkerFor([source]);
    final failed = await checker.check(bookFor([source]).entries, ChapterUpdateState());
    expect(failed.state.initialized, isFalse);
    source.blocked.clear();
    source.empty.clear();
    final readable = await checker.check(bookFor([source]).entries, failed.state);
    expect(readable.state.initialized, isTrue);
    expect(readable.newChapters, isEmpty);
    expect(readable.state.seen, {'v1:c1', 'v1:c2'});
  });

  test('partial outage preserves seen/notified and never resets progress', () async {
    final a = UpdateFixture('senkuro')..offline = true;
    final b = UpdateFixture('readmanga')..chapters = [ch('2')];
    final previous = reduceChapterCheck(ChapterUpdateState(), [release('1')], successfulSources: 1).state;
    final result = await checkerFor([a, b]).check(bookFor([a, b]).entries, previous);
    expect(result.state.seen, {'v1:c1', 'v1:c2'});
    expect(result.newChapters.single.source, 'readmanga');
    a.chapters = [ch('1'), ch('2', id: 'later-copy')];
    a.offline = false;
    final next = await checkerFor([a, b]).check(bookFor([a, b]).entries, result.state);
    expect(next.newChapters, isEmpty);
    expect(next.available['v1:c2']!.map((e) => e.source).toSet(), {'senkuro', 'readmanga'});
  });

  test('paid/locked, empty, unavailable and unnumbered releases do not count', () async {
    final source = UpdateFixture('remanga')..chapters = [
      ch('1', id: 'paid', readable: false), ch('2', id: 'locked'),
      ch('3', id: 'empty'), const Chapter(id: 'special', name: 'Special')];
    source.blocked.add('locked');
    source.empty.add('empty');
    final result = await checkerFor([source]).check(bookFor([source]).entries, ChapterUpdateState(initialized: true));
    expect(result.newChapters, isEmpty);
    expect(result.state.seen, isEmpty);
    expect(source.pageCalls, ['locked', 'empty']);
    source.chapters = [ch('1', id: 'free-now')];
    final unlocked = await checkerFor([source]).check(bookFor([source]).entries, result.state);
    expect(unlocked.newChapters.single.key, 'v1:c1');
  });

  test('first detected accessible source wins, regardless of provider insertion order', () async {
    final a = UpdateFixture('senkuro')..chapters = [ch('2', id: 'a')]
      ..pendingPages = Completer<List<PageImage>>();
    final b = UpdateFixture('remanga')..chapters = [ch('2', id: 'b')]
      ..pendingPages = Completer<List<PageImage>>();
    final future = checkerFor([a, b]).check(bookFor([a, b]).entries, ChapterUpdateState(initialized: true));
    await Future.wait([a.requestedPages.future, b.requestedPages.future]);
    b.pendingPages!.complete([const PageImage('https://cdn.example/b.jpg')]);
    await Future<void>.delayed(Duration.zero);
    a.pendingPages!.complete([const PageImage('https://cdn.example/a.jpg')]);
    final result = await future;
    expect(result.newChapters.single.source, 'remanga');
    expect(result.available['v1:c2']!.length, 2);
  });

  test('v1 migration retains original storage, labels, entries and progress across restart', () async {
    final legacy = jsonEncode([{
      'title': 'Example', 'entries': {'senkuro': UpdateFixture('senkuro').entry.toJson()},
      'lastChapter': 'Глава 7.5: Old subtitle', 'lastSource': 'senkuro'}]);
    SharedPreferences.setMockInitialValues({LibraryStore.legacyStorageKey: legacy});
    final library = LibraryStore();
    await library.load();
    final saved = library.items.single;
    expect(saved.updates.initialized, isFalse);
    expect(saved.progress.single.chapter.name, 'Глава 7.5: Old subtitle');
    expect(saved.lastSource, 'senkuro');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LibraryStore.legacyStorageKey), legacy);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.items.single.id, saved.id);
    expect(restored.items.single.toJson(), saved.toJson());
    await restored.load();
    expect(restored.items.length, 1);
  });

  test('malformed migration cannot overwrite either original or future version', () async {
    for (final values in [
      {LibraryStore.legacyStorageKey: '[broken'},
      {LibraryStore.storageKey: '{"version":99,"books":[]}'}]) {
      SharedPreferences.setMockInitialValues(values);
      final library = LibraryStore();
      await library.load();
      expect(library.loadError, isNotNull);
      await expectLater(library.add(bookFor([UpdateFixture('senkuro')])), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      for (final entry in values.entries) {
        expect(prefs.getString(entry.key), entry.value);
      }
    }
  });

  test('durable seen/notified inbox and progress survive app restart and later duplicate', () async {
    final a = UpdateFixture('senkuro')..chapters = [ch('1')];
    final b = UpdateFixture('remanga');
    final checker = checkerFor([a, b]);
    final library = LibraryStore();
    await library.load();
    await library.add(bookFor([a, b]));
    final id = library.items.single.id;
    expect((await library.check(id, checker)).newChapters, isEmpty);
    a.chapters.add(ch('2.5', id: 'new', subtitle: 'Original'));
    expect((await library.check(id, checker)).newChapters.single.key, 'v1:c2.5');
    final restarted = LibraryStore();
    await restarted.load();
    b.chapters = [ch('2.50', id: 'different', subtitle: 'New subtitle')];
    a.offline = true;
    final duplicate = await restarted.check(id, checker);
    expect(duplicate.newChapters, isEmpty);
    expect(restarted.items.single.updates.inbox['v1:c2.5']!.source, 'senkuro');
    await restarted.markRead(restarted.items.single.toUnified(), b.chapters.single, b.key);
    final again = LibraryStore();
    await again.load();
    expect(again.items.single.lastSource, 'remanga');
    expect(canonicalChapterKey(again.items.single.progress.single.chapter), 'v1:c2.5');
    expect(again.items.single.updates.inbox, isEmpty);
    expect(again.items.single.updates.notified, {'v1:c2.5'});
    expect((await again.check(id, checker)).newChapters, isEmpty);
  });

  test('overlapping checks serialize and notify a chapter once', () async {
    final a = UpdateFixture('senkuro');
    final library = LibraryStore();
    await library.add(bookFor([a]));
    final id = library.items.single.id;
    await library.check(id, checkerFor([a]));
    a.chapters = [ch('1')];
    final results = await Future.wait([
      library.check(id, checkerFor([a])), library.check(id, checkerFor([a]))]);
    expect(results.expand((r) => r.newChapters).length, 1);
  });

  test('all three linked sites and duplicate translations produce one new decimal chapter', () async {
    final sources = ['senkuro', 'readmanga', 'remanga'].map(UpdateFixture.new).toList();
    final library = LibraryStore();
    await library.add(bookFor(sources));
    final id = library.items.single.id;
    await library.check(id, checkerFor(sources));
    for (final source in sources) {
      source.chapters = [ch('1.2500', id: '${source.key}-a'), ch('1.25', id: '${source.key}-b')];
    }
    final result = await library.check(id, checkerFor(sources));
    expect(result.newChapters.single.key, 'v1:c1.25');
    expect(result.available['v1:c1.25']!.length, 6);
    expect(library.items.single.updates.notified, {'v1:c1.25'});
    for (final source in sources) { source.offline = true; }
    final failed = await library.check(id, checkerFor(sources));
    expect(failed.state.toJson(), result.state.toJson());
  });

  test('unique exact titles across individual sites save as one favorite without losing progress', () async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga', title: 'EXAMPLE!');
    final library = LibraryStore();
    await library.markRead(bookFor([a]), ch('1'), a.key);
    await library.add(bookFor([b], title: b.title));
    expect(library.items.single.entries.keys, ['senkuro', 'readmanga']);
    expect(library.items.single.lastChapter, 'Глава 1: ');
    expect(library.items.single.progress.single.source, 'senkuro');
  });

  test('ambiguous same-site title IDs stay separate and discovery never selects the first', () async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga')..searchResults = [
      const MangaEntry(source: 'readmanga', id: '/one', title: 'EXAMPLE'),
      const MangaEntry(source: 'readmanga', id: '/two', title: 'Example!')];
    expect(mergeEntries([a.entry, ...b.searchResults!]).length, 3);
    final repository = CatalogRepository(sources: {a.key: a, b.key: b});
    expect((await repository.findOtherSources(bookFor([a]))).entries.keys, ['senkuro']);
    b.searchResults = [const MangaEntry(source: 'readmanga', id: '/localized', title: 'Другой перевод')];
    expect((await repository.findOtherSources(bookFor([a]))).entries.keys, ['senkuro']);
  });

  test('known ambiguity survives saving/restart and prevents reverse automatic links', () async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga');
    final catalog = mergeEntries([a.entry, b.entry,
      const MangaEntry(source: 'readmanga', id: 'collision', title: 'Example')]);
    final ambiguous = catalog.firstWhere((book) => book.entries.containsKey('senkuro'));
    expect(ambiguous.requiresLinkApproval, isTrue);
    final library = LibraryStore();
    await library.add(ambiguous);
    final restored = LibraryStore();
    await restored.load();
    final saved = restored.items.single.toUnified();
    expect(saved.requiresLinkApproval, isTrue);
    final repository = CatalogRepository(sources: {a.key: a, b.key: b});
    expect((await repository.findOtherSources(saved)).entries.keys, ['senkuro']);
    expect(restored.get(bookFor([b])), isNull);
    await restored.connect(saved, bookFor([b]), approved: true);
    expect(restored.items.single.entries.keys, ['senkuro', 'readmanga']);
  });

  test('explicit approved linking unifies favorites and retains both progress histories', () async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga', title: 'Локализованное название');
    final library = LibraryStore();
    await library.markRead(bookFor([a]), ch('1'), a.key);
    await library.markRead(bookFor([b], title: b.title), ch('2'), b.key);
    expect(library.items.length, 2);
    await expectLater(library.connect(bookFor([a]), bookFor([b]), approved: false), throwsStateError);
    expect(library.items.length, 2);
    await library.connect(bookFor([a]), bookFor([b]), approved: true);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.items.single.entries.keys, ['senkuro', 'readmanga']);
    expect(restored.items.single.progress.map((p) => p.source), ['senkuro', 'readmanga']);
    expect(restored.get(bookFor([b]))!.id, restored.items.single.id);
  });

  test('same normalized titles with conflicting source IDs remain distinct favorites', () async {
    final source = UpdateFixture('senkuro');
    final first = bookFor([source]);
    final second = UnifiedManga(title: 'Example!', entries: {'senkuro':
      const MangaEntry(source: 'senkuro', id: 'different-series', title: 'Example!')});
    final library = LibraryStore();
    await library.add(first);
    await library.add(second);
    expect(library.items.length, 2);
    await expectLater(library.connect(first, second, approved: true), throwsStateError);
    expect(library.items.length, 2);
  });

  testWidgets('manual check shows chosen source/chapter and opens reader offline', (tester) async {
    final source = UpdateFixture('remanga');
    final library = LibraryStore();
    await library.add(bookFor([source]));
    await library.check(library.items.single.id, checkerFor([source]));
    source.chapters = [ch('2.5', subtitle: 'New')];
    final repository = CatalogRepository(sources: {source.key: source});
    await tester.pumpWidget(MaterialApp(home: ChapterUpdatesPage(library: library, repository: repository)));
    await tester.tap(find.text('Проверить новые главы'));
    await tester.pumpAndSettle();
    expect(find.text('Глава 2.5: New'), findsOneWidget);
    expect(find.text('Первым обнаружен: remanga'), findsOneWidget);
    source.empty.add('local'); // Opening the fixture must not request image bytes.
    await tester.tap(find.text('Глава 2.5: New'));
    await tester.pumpAndSettle();
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.sourceKey, 'remanga');
    expect(canonicalChapterKey(reader.chapter), 'v1:c2.5');
    expect(source.pageCalls, contains('local'));
  });

  testWidgets('localized source linking requires confirmation; cancel leaves storage untouched', (tester) async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga', title: 'Другой перевод');
    final library = LibraryStore();
    await library.add(bookFor([a]));
    final repository = CatalogRepository(sources: {a.key: a, b.key: b});
    await tester.pumpWidget(MaterialApp(home: SourceLinkPage(book: bookFor([a]), repository: repository, library: library)));
    await tester.tap(find.text('Найти варианты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Другой перевод'));
    await tester.pumpAndSettle();
    expect(find.text('Это одно произведение?'), findsOneWidget);
    expect(library.items.single.entries.length, 1);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(library.items.single.entries.length, 1);
  });

  testWidgets('a later source can be opened when the durable first detection is offline', (tester) async {
    final a = UpdateFixture('senkuro');
    final b = UpdateFixture('readmanga');
    final library = LibraryStore();
    await library.add(bookFor([a, b]));
    final id = library.items.single.id;
    await library.check(id, checkerFor([a, b]));
    a.chapters = [ch('3', id: 'winner')];
    await library.check(id, checkerFor([a, b]));
    a.offline = true;
    b.chapters = [ch('3', id: 'later', subtitle: 'Other translation')];
    final repository = CatalogRepository(sources: {a.key: a, b.key: b});
    final restored = LibraryStore();
    await restored.load();
    await tester.pumpWidget(MaterialApp(home: ChapterUpdatesPage(library: restored, repository: repository)));
    expect(find.text('Первым обнаружен: senkuro'), findsOneWidget);
    await tester.tap(find.text('Проверить новые главы'));
    await tester.pumpAndSettle();
    final alternative = find.text('Открыть readmanga · Глава 3: Other translation');
    expect(alternative, findsOneWidget);
    b.empty.add('later');
    await tester.tap(alternative);
    await tester.pumpAndSettle();
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.sourceKey, 'readmanga');
    expect(reader.chapter.id, 'later');
    expect(restored.items.single.updates.notified, {'v1:c3'});
  });
}

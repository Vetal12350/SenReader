import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/chapter_identity.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/library_store.dart';

class FakeSource implements MangaSource {
  FakeSource(this.key, {this.available = true});
  @override final String key;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => {};
  bool available;
  bool readable = true;
  List<Chapter> chapters = [];
  int pageCalls = 0;
  int detailCalls = 0;
  int searchCalls = 0;
  final entry = const MangaEntry(source: 'fixture', id: '1', title: 'Example');

  @override Future<List<MangaEntry>> popular() => search('');
  @override Future<List<MangaEntry>> search(String query) async {
    searchCalls++;
    return [MangaEntry(source: key, id: '1', title: 'Example')];
  }
  @override Future<MangaDetail> detail(MangaEntry record) async {
    detailCalls++;
    if (!available) throw SourceException('offline');
    return MangaDetail(entry: record, chapters: chapters);
  }
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    pageCalls++;
    if (!readable || !available) throw SourceException('locked');
    return [const PageImage('https://cdn.example.com/page.jpg')];
  }
}

Future<LibraryStore> makeLibrary(List<FakeSource> sources) async {
  final library = LibraryStore();
  await library.load();
  await library.add(UnifiedManga(title: 'Example', entries: {
    for (final source in sources)
      source.key: MangaEntry(source: source.key, id: '1', title: 'Example'),
  }));
  return library;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('chapter key ignores subtitle, source ID and trailing zeros', () {
    expect(canonicalChapterKey(const Chapter(id: 'a', name: 'Глава 12.50: First')),
        'v0:c12.5');
    expect(canonicalChapterKey(const Chapter(id: 'b', name: 'Глава 12.5: Another')),
        'v0:c12.5');
    expect(canonicalChapterKey(const Chapter(id: 'abc', name: 'Глава 8 (т. 2)')),
        'v2:c8');
    expect(canonicalChapterKey(const Chapter(id: 'slug', name: 'Chapter 08.00 (vol. 02)')),
        'v2:c8');
    expect(canonicalChapterKey(const Chapter(id: 'unknown', name: 'Special chapter')),
        isNull);
  });

  test('first successful source scan creates baseline without alerts', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 'x', name: 'Глава 1'),
                    const Chapter(id: 'y', name: 'Глава 2')];
    final library = await makeLibrary([source]);
    final report = await ChapterChecker(
      repository: CatalogRepository(sources: {source.key: source}),
      library: library).check();
    expect(report.discoveries, isEmpty);
    expect(source.pageCalls, 0);
    expect(library.items.single.initializedSources, contains('senkuro'));
    expect(library.items.single.seenChapterKeys, {'v0:c1', 'v0:c2'});
  });

  test('one new fractional chapter is notified exactly once after restart', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(
      repository: CatalogRepository(sources: {'senkuro': source}),
      library: library);
    await checker.check();
    source.chapters = [
      const Chapter(id: 'new', name: 'Глава 1.5: Hello'),
      const Chapter(id: '1', name: 'Глава 1'),
    ];
    final report = await checker.check();
    expect(report.discoveries.map((d) => d.canonicalKey), ['v0:c1.5']);
    expect((await checker.check()).discoveries, isEmpty);

    final restored = LibraryStore();
    await restored.load();
    final otherChecker = ChapterChecker(
      repository: CatalogRepository(sources: {'senkuro': source}),
      library: restored);
    expect((await otherChecker.check()).discoveries, isEmpty);
    expect(restored.items.single.seenChapterKeys, contains('v0:c1.5'));
  });

  test('both linked sources are scanned, identical new chapter alerts once', () async {
    final senkuro = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 'first', name: 'Глава 3')];
    final readmanga = FakeSource('readmanga')
      ..chapters = [const Chapter(id: 'other', name: 'Глава 3')];
    final library = await makeLibrary([senkuro, readmanga]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': senkuro, 'readmanga': readmanga,
    }), library: library);
    expect((await checker.check()).discoveries, isEmpty);
    expect(library.items.single.initializedSources,
        containsAll(['senkuro', 'readmanga']));
    senkuro.chapters = [const Chapter(id: 's4', name: 'Глава 4')];
    readmanga.chapters = [const Chapter(id: 'r4', name: 'Глава 4')];
    final result = await checker.check();
    expect(result.discoveries.map((d) => d.canonicalKey), ['v0:c4']);
    expect(readmanga.detailCalls, greaterThan(1));
    expect((await checker.check()).discoveries, isEmpty);
  });

  test('changed subtitle does not alert and offline source preserves baseline', () async {
    final a = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 5: Old')];
    final library = await makeLibrary([a]);
    final checker = ChapterChecker(
      repository: CatalogRepository(sources: {'senkuro': a}),
      library: library);
    await checker.check();
    a.chapters = [const Chapter(id: 'new', name: 'Глава 5: New')];
    expect((await checker.check()).discoveries, isEmpty);
    a.available = false;
    expect((await checker.check()).warnings, isNotEmpty);
    expect(library.items.single.seenChapterKeys, contains('v0:c5'));
    a.available = true;
    a.chapters = [const Chapter(id: '6', name: 'Глава 6')];
    expect((await checker.check()).discoveries.single.canonicalKey, 'v0:c6');
  });

  test('unreadable chapter is not marked notified and retries when accessible', () async {
    final source = FakeSource('remanga')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(
      repository: CatalogRepository(sources: {'remanga': source}),
      library: library);
    await checker.check();
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    source.readable = false;
    expect((await checker.check()).discoveries, isEmpty);
    expect(library.items.single.seenChapterKeys, isNot(contains('v0:c2')));
    source.readable = true;
    expect((await checker.check()).discoveries.single.canonicalKey, 'v0:c2');
  });

  test('newly linked source silently baselines then reports its new chapter', () async {
    final a = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 's1', name: 'Глава 1')];
    final b = FakeSource('readmanga')
      ..chapters = [const Chapter(id: 'r99', name: 'Глава 99')];
    final library = await makeLibrary([a]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': a, 'readmanga': b,
    }), library: library);
    await checker.check();
    expect(b.detailCalls, 0);
    final linked = library.items.single.toUnified();
    linked.entries['readmanga'] =
        const MangaEntry(source: 'readmanga', id: '1', title: 'Example');
    await library.add(linked);
    expect((await checker.check()).discoveries, isEmpty);
    expect(library.items.single.preferredSource, 'senkuro');
    expect(library.items.single.initializedSources, contains('readmanga'));
    b.chapters = [const Chapter(id: 'r100', name: 'Глава 100')];
    expect((await checker.check()).discoveries.single.sourceKey, 'readmanga');
    expect((await checker.check()).discoveries, isEmpty);
  });

  test('already-read chapter from a linked source never alerts twice', () async {
    final a = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 's70', name: 'Глава 70')];
    final b = FakeSource('readmanga')
      ..chapters = [const Chapter(id: 'r70', name: 'Глава 70')];
    final library = await makeLibrary([a, b]);
    final book = library.items.single.toUnified();
    await library.setPreferredSource(book, 'readmanga');
    await library.markRead(book, b.chapters.first, 'readmanga');
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': a, 'readmanga': b,
    }), library: library);
    await checker.check();
    a.chapters = [
      const Chapter(id: 's70new', name: 'Глава 70'),
      const Chapter(id: 's71', name: 'Глава 71'),
    ];
    b.available = false;
    final next = await checker.check();
    expect(next.discoveries.map((d) => d.canonicalKey), ['v0:c71']);
    expect(next.warnings, isNotEmpty);
    expect((await checker.check()).discoveries, isEmpty);
  });

  test('old v1 bookmarks and reading progress remain unchanged on load', () async {
    SharedPreferences.setMockInitialValues({
      LibraryStore.storageKey:
          '[{"title":"Example","entries":{"senkuro":{"source":"senkuro",'
          '"id":"a","title":"Example","coverUrl":""}},'
          '"lastChapter":"Глава 7","lastSource":"senkuro"}]',
    });
    final library = LibraryStore();
    await library.load();
    expect(library.items.single.lastChapter, 'Глава 7');
    expect(library.items.single.lastSource, 'senkuro');
    expect(library.items.single.initializedSources, isEmpty);
    expect(library.items.single.seenChapterKeys, isEmpty);
  });

  test('source choice changed during page verification discards stale discovery', () async {
    final source = _DelayedPagesSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final other = FakeSource('remanga');
    final library = await makeLibrary([source, other]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': source, 'remanga': other,
    }), library: library);
    await checker.check();
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    source.pending = Completer<List<PageImage>>();
    final checking = checker.check();
    await source.started.future;
    await library.setPreferredSource(library.items.single.toUnified(), 'remanga');
    source.pending!.complete([const PageImage('https://cdn.example.com/2.jpg')]);
    expect((await checking).discoveries, isEmpty);
    expect(library.items.single.preferredSource, 'remanga');
    expect(library.items.single.seenChapterKeys, isNot(contains('v0:c2')));
  });

  test('ambiguous different-title sources are never silently joined', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final stranger = FakeSource('remanga')
      ..chapters = [const Chapter(id: '100', name: 'Глава 100')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {
      'senkuro': source,
      'remanga': _MismatchedSource(stranger),
    });
    await ChapterChecker(repository: repo, library: library).check();
    expect(library.items.single.entries.keys, ['senkuro']);
  });
}

class _DelayedPagesSource extends FakeSource {
  _DelayedPagesSource(super.key);
  Completer<List<PageImage>>? pending;
  final started = Completer<void>();
  @override Future<List<PageImage>> pages(Chapter chapter) {
    if (pending == null) return super.pages(chapter);
    if (!started.isCompleted) started.complete();
    return pending!.future;
  }
}

class _MismatchedSource extends FakeSource {
  _MismatchedSource(FakeSource _) : super('remanga');
  @override Future<List<MangaEntry>> search(String query) async => [
    const MangaEntry(source: 'remanga', id: 'other', title: 'Unrelated series'),
  ];
}

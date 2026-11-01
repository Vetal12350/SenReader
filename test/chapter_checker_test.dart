import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/chapter_identity.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
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
  final book = UnifiedManga(title: 'Example', entries: {
    for (final source in sources)
      source.key: MangaEntry(source: source.key, id: '1', title: 'Example'),
  });
  await library.setStatus(book, 'reading');
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

  test('a saved preferred ReadManga link remains trusted after title change',
      () async {
    final source = FakeSource('readmanga')
      ..chapters = [const Chapter(id: '112', name: 'Глава 112')];
    final store = LibraryStore();
    await store.load();
    await store.setStatus(UnifiedManga(title: 'Название в каталоге',
        entries: {'readmanga': const MangaEntry(source: 'readmanga',
            id: '123', title: 'Другое название на ReadManga')}), 'reading');
    final checker = ChapterChecker(
        repository: CatalogRepository(sources: {'readmanga': source}),
        library: store);
    final baseline = await checker.check(diagnostics: true);
    expect(baseline.discoveries, isEmpty);
    expect(baseline.diagnostics.single, contains('Глава 112'));
    expect(store.items.single.initializedSources, contains('readmanga'));
    source.chapters = [const Chapter(id: '113', name: 'Глава 113')];
    final next = await checker.check();
    expect(next.discoveries.map((item) => item.canonicalKey), ['v0:c113']);
  });

  test('manual report notes missing chapter publication date and status',
      () async {
    final source = FakeSource('readmanga')
      ..chapters = [const Chapter(id: '113', name: 'Глава 113')];
    final store = await makeLibrary([source]);
    final checker = ChapterChecker(
        repository: CatalogRepository(sources: {'readmanga': source}),
        library: store);
    final result = await checker.check(diagnostics: true);
    expect(result.diagnostics.single, contains('дата неизвестна'));
    expect(result.diagnostics.single, contains('известна: нет'));
    expect(result.diagnostics.single, contains('прочитана: нет'));
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

  test('first account scan catches a recently published unread chapter after 112',
      () async {
    final oldDate = DateTime.now().subtract(const Duration(days: 7));
    final newDate = DateTime.now().subtract(const Duration(hours: 2));
    final source = FakeSource('readmanga')..chapters = [
      Chapter(id: '113', name: 'Глава 113', publishedAt: newDate),
      Chapter(id: '112', name: 'Глава 112', publishedAt: oldDate),
    ];
    final library = await makeLibrary([source]);
    await library.switchProfile('googleUser');
    final book = UnifiedManga(title: 'Example', entries: {
      'readmanga': const MangaEntry(
          source: 'readmanga', id: '1', title: 'Example'),
    });
    await library.setStatus(book, 'reading');
    await library.markRead(book, source.chapters.last, 'readmanga');
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'readmanga': source,
    }), library: library);
    final first = await checker.check();
    expect(first.discoveries.map((d) => d.canonicalKey), ['v0:c113']);
    expect(library.items.single.initializedSources, contains('readmanga'));
    // The foreground inbox/background notification service records delivery
    // after check() returns; simulate that handoff to prevent replay.
    await ChapterInboxStore().add(library.items.single.key, 'Example', '',
        'readmanga', source.chapters.first);
    expect((await checker.check()).discoveries, isEmpty);
    final reopened = LibraryStore();
    await reopened.load();
    expect(reopened.profileId, 'googleUser');
    expect(reopened.items.single.seenChapterKeys, contains('v0:c113'));
    expect(reopened.isChapterRead(book, source.chapters.last, 'readmanga'), true);
  });

  test('first scan does not alert old unread chapters', () async {
    final source = FakeSource('readmanga')..chapters = [
      Chapter(id: '113', name: 'Глава 113',
          publishedAt: DateTime.now().subtract(const Duration(days: 7))),
      const Chapter(id: '112', name: 'Глава 112'),
    ];
    final library = await makeLibrary([source]);
    await library.setStatus(library.items.single.toUnified(), 'reading');
    await library.markRead(library.items.single.toUnified(),
        source.chapters.last, 'readmanga');
    final report = await ChapterChecker(
      repository: CatalogRepository(sources: {'readmanga': source}),
      library: library).check();
    expect(report.discoveries, isEmpty);
    expect(source.pageCalls, 0);
    expect(library.items.single.seenChapterKeys, contains('v0:c113'));
  });

  test('old silent baseline can recover recent chapter 113 exactly once', () async {
    final now = DateTime.now();
    final source = FakeSource('readmanga')..chapters = [
      Chapter(id: '113', name: 'Глава 113',
        publishedAt: now.subtract(const Duration(hours: 2))),
      Chapter(id: '112', name: 'Глава 112',
        publishedAt: now.subtract(const Duration(days: 7))),
    ];
    final library = await makeLibrary([source]);
    await library.setStatus(library.items.single.toUnified(), 'reading');
    await library.markRead(library.items.single.toUnified(),
        source.chapters.last, 'readmanga');
    final key = library.items.single.key;
    await library.recordChapterScan(key, 'readmanga', ['v0:c112', 'v0:c113']);
    final checker = ChapterChecker(
        repository: CatalogRepository(sources: {'readmanga': source}),
        library: library);
    final first = await checker.check();
    expect(first.discoveries.map((item) => item.canonicalKey), ['v0:c113']);
    await ChapterInboxStore().add(key, 'Example', '', 'readmanga',
        source.chapters.first);
    expect((await checker.check()).discoveries, isEmpty);
    expect(library.items.single.readChapterKeys, contains('readmanga|v0:c112'));
  });

  test('archived inbox chapter 113 is not sent again', () async {
    final source = FakeSource('readmanga')..chapters = [
      Chapter(id: '113', name: 'Глава 113',
        publishedAt: DateTime.now().subtract(const Duration(hours: 1))),
      const Chapter(id: '112', name: 'Глава 112'),
    ];
    final library = await makeLibrary([source]);
    await library.setStatus(library.items.single.toUnified(), 'reading');
    await library.markRead(library.items.single.toUnified(),
        source.chapters.last, 'readmanga');
    final key = library.items.single.key;
    await library.recordChapterScan(key, 'readmanga', ['v0:c112', 'v0:c113']);
    await ChapterInboxStore().add(key, 'Example', '', 'readmanga',
        source.chapters.first);
    final inbox = ChapterInboxStore();
    final added = await inbox.load();
    await inbox.hideEntry(added.single.key);
    expect((await ChapterChecker(
        repository: CatalogRepository(sources: {'readmanga': source}),
        library: library).check()).discoveries, isEmpty);
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

  test('only Reading titles are scanned in manual and automatic modes', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source,
    }), library: library);
    for (final status in ['planned', 'completed', 'dropped', 'viewed']) {
      await library.setStatus(book, status);
      final manual = await checker.check(diagnostics: true);
      final background = await checker.check(smartSchedule: true);
      expect(manual.checkedTitles, 0, reason: status);
      expect(manual.checkedSources, 0, reason: status);
      expect(manual.discoveries, isEmpty, reason: status);
      expect(background.checkedSources, 0, reason: status);
      expect(source.detailCalls, 0, reason: status);
      expect(library.get(book)!.initializedSources, isEmpty, reason: status);
    }
    await library.setStatus(book, 'reading');
    expect((await checker.check()).checkedSources, 1);
    expect(source.detailCalls, 1);
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    await library.setStatus(book, 'completed');
    expect((await checker.check()).checkedSources, 0);
    expect((await checker.check(smartSchedule: true)).checkedSources, 0);
    expect(source.detailCalls, 1);
    expect(library.get(book)!.seenChapterKeys, isNot(contains('v0:c2')));
    await library.setStatus(book, 'reading');
    expect((await checker.check()).discoveries.single.canonicalKey, 'v0:c2');
  });

  test('switch to Completed while chapter loads prevents alerts and seen marks',
      () async {
    final source = _DelayedPagesSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': source,
    }), library: library);
    await checker.check();
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    source.pending = Completer<List<PageImage>>();
    final checking = checker.check();
    await source.started.future;
    await library.setStatus(book, 'completed');
    source.pending!.complete([const PageImage('https://cdn.example.com/2.jpg')]);
    expect((await checking).discoveries, isEmpty);
    expect(library.get(book)!.seenChapterKeys, isNot(contains('v0:c2')));
    expect(library.get(book)!.status, 'completed');
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

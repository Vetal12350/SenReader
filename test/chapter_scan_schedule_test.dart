import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/data/library_store.dart';

class _ScheduleFakeSource implements MangaSource {
  _ScheduleFakeSource(this.key);
  @override final String key;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => {};
  int scans = 0;
  bool online = true;
  List<Chapter> chapters = [const Chapter(id: '1', name: 'Глава 1')];
  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<List<MangaEntry>> search(String query) async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async {
    scans++;
    if (!online) throw SourceException('offline');
    return MangaDetail(entry: entry, chapters: chapters);
  }
  @override Future<List<PageImage>> pages(Chapter chapter) async =>
      [const PageImage('https://cdn.example.com/1.jpg')];
}

Future<(LibraryStore, UnifiedManga)> _book(Map<String, _ScheduleFakeSource> sources) async {
  final library = LibraryStore();
  await library.load();
  final book = UnifiedManga(title: 'Sample', entries: {
    for (final source in sources.values)
      source.key: MangaEntry(source: source.key, id: 'id', title: 'Sample'),
  });
  await library.add(book);
  return (library, book);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('policy checks reading earlier than planned or completed', () {
    final now = DateTime(2026, 11, 1, 12);
    final halfHourAgo = now.subtract(const Duration(minutes: 30))
        .millisecondsSinceEpoch;
    expect(ChapterScanPolicy.isDue('reading', halfHourAgo, now), true);
    expect(ChapterScanPolicy.isDue('planned', halfHourAgo, now), false);
    expect(ChapterScanPolicy.isDue('completed', halfHourAgo, now), false);
    expect(ChapterScanPolicy.isDue('reading', null, now), true);
    expect(ChapterScanPolicy.isDue('reading', now.millisecondsSinceEpoch + 1000,
        now), true);
  });

  test('smart scan respects per-book per-source timing, manual bypasses', () async {
    final a = _ScheduleFakeSource('senkuro');
    final b = _ScheduleFakeSource('readmanga');
    final (library, book) = await _book({a.key: a, b.key: b});
    await library.setStatus(book, 'reading');
    final checker = ChapterChecker(repository:
        CatalogRepository(sources: {a.key: a, b.key: b}), library: library);
    final first = await checker.check(smartSchedule: true);
    expect(first.checkedSources, 2);
    expect(first.discoveries, isEmpty);
    final next = await checker.check(smartSchedule: true);
    expect(next.checkedSources, 0);
    expect(next.skippedSources, 2);
    expect(a.scans, 1);
    expect(b.scans, 1);
    final manual = await checker.check();
    expect(manual.checkedSources, 2);
    expect(a.scans, 2);
    expect(b.scans, 2);
    expect(library.get(book)?.preferredSource, 'senkuro');
  });

  test('manual refresh schedules subsequent background work', () async {
    final source = _ScheduleFakeSource('senkuro');
    final (library, book) = await _book({source.key: source});
    await library.setStatus(book, 'reading');
    final checker = ChapterChecker(repository:
        CatalogRepository(sources: {source.key: source}), library: library);
    expect((await checker.check()).checkedSources, 1);
    expect((await checker.check(smartSchedule: true)).checkedSources, 0);
    expect(source.scans, 1);
  });

  test('large library is staggered across multiple background runs', () async {
    final source = _ScheduleFakeSource('senkuro');
    final library = LibraryStore();
    await library.load();
    for (var i = 0; i < 17; i++) {
      await library.add(UnifiedManga(title: 'Book $i', entries: {
        'senkuro': MangaEntry(source: 'senkuro', id: 'id$i',
            title: 'Book $i'),
      }));
    }
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      'senkuro': source,
    }), library: library);
    final first = await checker.check(smartSchedule: true);
    expect(first.checkedSources, ChapterChecker.maxBackgroundSourcesPerRun);
    expect(first.skippedSources, 5);
    final second = await checker.check(smartSchedule: true);
    expect(second.checkedSources, 5);
    expect(second.skippedSources, 12);
    expect(source.scans, 17);
  });

  test('schedule timestamps are isolated between guest and account', () async {
    final a = _ScheduleFakeSource('senkuro');
    final (library, book) = await _book({a.key: a});
    final repo = CatalogRepository(sources: {a.key: a});
    await library.setStatus(book, 'reading');
    await ChapterChecker(repository: repo, library: library)
        .check(smartSchedule: true);
    expect(a.scans, 1);
    await library.switchProfile('userA');
    await library.setStatus(book, 'reading');
    await ChapterChecker(repository: repo, library: library)
        .check(smartSchedule: true);
    expect(a.scans, 2);
    await library.switchProfile(null);
    await ChapterChecker(repository: repo, library: library)
        .check(smartSchedule: true);
    expect(a.scans, 2);
  });

  test('failed source does not change progress and waits before retry', () async {
    final a = _ScheduleFakeSource('senkuro')..online = false;
    final (library, book) = await _book({a.key: a});
    await library.setStatus(book, 'reading');
    final checker = ChapterChecker(repository:
        CatalogRepository(sources: {a.key: a}), library: library);
    final first = await checker.check(smartSchedule: true);
    expect(first.warnings, isNotEmpty);
    expect((await checker.check(smartSchedule: true)).checkedSources, 0);
    expect(a.scans, 1);
    expect(library.items.single.initializedSources, isEmpty);
  });

  test('last run persists independently for each profile', () async {
    final store = ChapterScanScheduleStore();
    final summary = ChapterBackgroundScanSummary(
        at: DateTime(2026, 11, 1, 12), checkedSources: 3,
        skippedSources: 5, foundChapters: 1, warnings: 0);
    await store.recordRun('userA', summary);
    expect((await store.lastRun('userA'))?.checkedSources, 3);
    expect((await store.lastRun(''))?.checkedSources, isNull);
  });
}

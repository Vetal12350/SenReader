import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/unavailable_chapters.dart';
import 'automatic_scan_reliability_test.dart' show ControlledSource;
import 'chapter_checker_test.dart' show makeLibrary;

/// A chapter the source lists but answers 404 for must not be re-requested on
/// every automatic run (seen overnight: ~180 identical ReadManga 404 checks
/// that used up the worker budget), yet must still arrive once it is served.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persistent vs transient errors', () {
    expect(UnavailableChapters.isPersistent(
      SourceException('HTTP 404. Сайт или зеркало недоступны.')), isTrue);
    expect(UnavailableChapters.isPersistent(
      SourceException('ReadManga: изображение недоступно (HTTP 410).')), isTrue);
    expect(UnavailableChapters.isPersistent(
      SourceException('ReadManga: главы нет в публичном доступе (удалена или закрыта).')), isTrue);
    expect(UnavailableChapters.isPersistent(SourceException('HTTP 403.')), isFalse);
    expect(UnavailableChapters.isPersistent(SourceException('HTTP 429')), isFalse);
    expect(UnavailableChapters.isPersistent(SourceException('Нет соединения с ReadManga')), isFalse);
    expect(UnavailableChapters.isPersistent(StateError('x')), isFalse);
  });

  test('a 404 chapter is paused, not retried each run, and delivered once served', () async {
    var now = DateTime(2026, 11, 17, 9);
    final unavailable = UnavailableChapters(clock: () => now);
    final source = ControlledSource('readmanga')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    ChapterChecker checker() =>
        ChapterChecker(repository: repo, library: library, unavailable: unavailable);
    await checker().check(); // silent baseline
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    var pageRequests = 0;
    var served = false;
    source.onPages = (_) async {
      pageRequests++;
      if (!served) throw SourceException('HTTP 404. Сайт или зеркало недоступны.');
      return [const PageImage('https://cdn.example.com/2.jpg')];
    };
    Future<ChapterScanReport> run() async {
      await (await ChapterScanQueue().database()).update('jobs', {'due': 0, 'lease': 0});
      return checker().check(smartSchedule: true);
    }

    final first = await run();
    expect(pageRequests, 1);
    expect(first.warnings, isEmpty, reason: 'not a source failure');
    expect(first.failedSources, 0);

    now = now.add(const Duration(hours: 1));
    await run();
    expect(pageRequests, 1, reason: 'paused: no request within the backoff');

    now = now.add(const Duration(hours: 6));
    served = true;
    await run();
    expect(pageRequests, 2, reason: 'retried after the backoff');
    expect((await ChapterInboxStore(profileId: '').load()).single.chapterId, '2');
  });

  test('a listed chapter with no pages is paused too', () async {
    var now = DateTime(2026, 11, 23, 9);
    final unavailable = UnavailableChapters(clock: () => now);
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    ChapterChecker checker() =>
        ChapterChecker(repository: repo, library: library, unavailable: unavailable);
    await checker().check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    var pageRequests = 0;
    source.onPages = (_) async { pageRequests++; return const <PageImage>[]; };
    for (var i = 0; i < 2; i++) {
      await (await ChapterScanQueue().database()).update('jobs', {'due': 0, 'lease': 0});
      await checker().check(smartSchedule: true);
      now = now.add(const Duration(hours: 1));
    }
    expect(pageRequests, 1, reason: 'empty chapter paused within the backoff');
  });

  test('network errors are not paused', () async {
    final unavailable = UnavailableChapters();
    final source = ControlledSource('readmanga')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    var pageRequests = 0;
    source.onPages = (_) async {
      pageRequests++;
      throw SourceException('Нет соединения с ReadManga');
    };
    for (var i = 0; i < 2; i++) {
      await (await ChapterScanQueue().database()).update('jobs', {'due': 0, 'lease': 0});
      await ChapterChecker(repository: repo, library: library, unavailable: unavailable)
        .check(smartSchedule: true);
    }
    expect(pageRequests, 2);
  });
}

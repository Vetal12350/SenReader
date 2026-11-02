import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/local_source_gate.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/library_store.dart';
import 'chapter_checker_test.dart' show FakeSource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final count in [70, 200]) {
    test('$count jobs survive restart, interruption and retain equal turns', () async {
      final jobs = [for (var i = 0; i < count; i++) ScanJob('book$i', 'senkuro', '$i')];
      final q = ChapterScanQueue();
      await q.reconcile('a', jobs);
      final visited = <String>{};
      final abandoned = (await q.claim('a', 'senkuro', 1000))!;
      visited.add(abandoned.job.key);
      for (var i = 1; i < count; i++) {
        final next = (await ChapterScanQueue().claim('a', 'senkuro', 1000 + i))!;
        expect(visited.add(next.job.key), isTrue);
        await q.finish('a', next, 1000 + i, success: true);
      }
      expect(await q.claim('a', 'senkuro', 2000), isNull);
      final retry = (await q.claim('a', 'senkuro', 302000))!;
      expect(retry.job.key, abandoned.job.key);
      await q.finish('a', abandoned, 302001, success: true); // stale owner
      expect(await q.claim('a', 'senkuro', 302002), isNull);
      expect(visited.length, count);
    });
  }
  test('budget replaces count cap; next run continues with remaining books', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = LibraryStore();
    await library.load();
    for (var i = 0; i < 70; i++) {
      await library.setStatus(UnifiedManga(title: 'Book $i', entries: {
        source.key: MangaEntry(source: source.key, id: '$i', title: 'Book $i'),
      }), 'reading');
    }
    var done = 0;
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source}), library: library,
      elapsed: () => Duration(seconds: done), afterPair: () async { done++; });
    expect((await checker.check(smartSchedule: true,
      budget: const Duration(seconds: 20))).checkedSources, 20);
    final next = await ChapterChecker(repository: checker.repository,
      library: library).check(smartSchedule: true);
    expect(next.checkedSources, 50);
    expect(source.detailCalls, 70);
  });
  test('429 cooldown survives restart and UID switch; other provider remains eligible', () async {
    final q = ChapterScanQueue();
    final db = await q.database();
    await q.reconcile('a', [ScanJob('x', 'senkuro', '1'), ScanJob('x', 'readmanga', '1')]);
    await q.reconcile('b', [ScanJob('x', 'senkuro', '1')]);
    await db.insert('providers', {'source': 'senkuro'});
    await LocalSourceGate('senkuro').response(429, '3600');
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(await ChapterScanQueue().claim('a', 'senkuro', now), isNull);
    expect(await ChapterScanQueue().claim('b', 'senkuro', now), isNull);
    expect(await q.claim('a', 'readmanga', now), isNotNull);
  });
  for (final provider in ['senkuro', 'readmanga']) {
    test('background 403 cooldown cannot block explicit foreground $provider access', () async {
      final db = await ChapterScanQueue().database();
      await db.insert('providers', {'source': provider},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await LocalSourceGate(provider).response(403, null);

      var sends = 0;
      Future<int> request() async {
        sends++;
        return 200;
      }

      // The foreground catalog/reader never consumes the background lease.
      expect(LocalSourceGate.isBackgroundScan, isFalse);
      expect(await LocalSourceGate.runScoped(provider, request), 200);
      expect(sends, 1);

      // The same source stays blocked for automatic checks: no circumvention
      // of the provider's restriction or extra background HTTP requests.
      await expectLater(runZoned(
          () => LocalSourceGate.runScoped(provider, request),
          zoneValues: {LocalSourceGate.backgroundScanKey: true}),
        throwsA(isA<StateError>()));
      expect(sends, 1);

      // An explicit foreground request that receives 403 still surfaces it;
      // the gate must not automatically retry or suppress a site refusal.
      await expectLater(LocalSourceGate.runScoped(provider,
          () async { sends++; throw StateError('HTTP 403'); }),
          throwsA(isA<StateError>()));
      expect(sends, 2);
    });

    test('background 429 Retry-After cannot freeze foreground $provider', () async {
      final db = await ChapterScanQueue().database();
      await db.insert('providers', {'source': provider},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await LocalSourceGate(provider).response(429, '3600');
      var calls = 0;
      expect(await LocalSourceGate.runScoped(provider, () async {
        calls++;
        return 'manual request';
      }), 'manual request');
      await expectLater(runZoned(
          () => LocalSourceGate.runScoped(provider, () async { calls++; }),
          zoneValues: {LocalSourceGate.backgroundScanKey: true}),
          throwsA(isA<StateError>()));
      expect(calls, 1);
    });
  }

  test('offline retries preserve queue and profile isolation without OS permissions', () async {
    final q = ChapterScanQueue();
    await q.reconcile('', [ScanJob('x', 'readmanga', '1')]);
    await q.reconcile('uid', [ScanJob('x', 'readmanga', '1')]);
    final job = (await q.claim('', 'readmanga', 1000))!;
    await q.finish('', job, 1000, success: false);
    expect(await q.claim('', 'readmanga', 2000), isNull);
    expect(await q.claim('uid', 'readmanga', 2000), isNotNull);
    expect(await q.claim('', 'readmanga', 302000), isNotNull);
  });
  test('profile switch stops a scheduled runner before the next book', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = LibraryStore();
    await library.load();
    for (var i = 0; i < 3; i++) {
      await library.setStatus(UnifiedManga(title: 'Book $i', entries: {
        source.key: MangaEntry(source: source.key, id: '$i', title: 'Book $i'),
      }), 'reading');
    }
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source}), library: library,
      afterPair: () => library.switchProfile('other-uid'));
    expect((await checker.check(smartSchedule: true)).discoveries, isEmpty);
    expect(source.detailCalls, 1);
    expect(library.items, isEmpty);
    await library.switchProfile(null);
    expect((await ChapterChecker(repository: checker.repository, library: library)
      .check(smartSchedule: true)).checkedSources, 2);
  });
  test('offline scan retries without changing reading history', () async {
    final source = FakeSource('readmanga')..available = false;
    final library = LibraryStore();
    await library.load();
    await library.setStatus(UnifiedManga(title: 'Example', entries: {
      source.key: const MangaEntry(source: 'readmanga', id: '1', title: 'Example'),
    }), 'reading');
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source}), library: library);
    expect((await checker.check(smartSchedule: true)).warnings, isNotEmpty);
    expect(library.items.single.initializedSources, isEmpty);
    source.available = true;
    source.chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final db = await ChapterScanQueue().database();
    await db.update('jobs', {'due': 0});
    expect((await checker.check(smartSchedule: true)).checkedSources, 1);
    expect(library.items.single.readChapterKeys, isEmpty);
    expect(library.items.single.preferredSource, 'readmanga');
  });

}

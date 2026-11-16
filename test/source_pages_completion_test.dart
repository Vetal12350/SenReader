import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'automatic_scan_reliability_test.dart' show ControlledSource;
import 'chapter_checker_test.dart' show makeLibrary;

void main() {
 for (final stall in [false, true]) {
  test('pages ${stall ? "timeout" : "error"}: finish, late result fenced, retry once', () async {
   final source = ControlledSource('senkuro')..chapters = [const Chapter(id: '1', name: 'Глава 1')];
   final library = await makeLibrary([source]);
   final repo = CatalogRepository(sources: {source.key: source});
   await ChapterChecker(repository: repo, library: library).check();
   source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
   final pending = Completer<List<PageImage>>();
   var calls = 0;
   source.onPages = (_) { calls++; return stall ? pending.future : Future.error(StateError('synthetic')); };
   final db = await ChapterScanQueue().database();
   await db.update('jobs', {'due': 0});
   final watch = Stopwatch()..start();
   final result = await ChapterChecker(repository: repo, library: library,
     sourceSlice: const Duration(milliseconds: 100)).check(smartSchedule: true, budget: const Duration(milliseconds: 200));
   expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
   expect(result.warnings, isNotEmpty);
   expect(calls, 1);
   expect(await ChapterInboxStore(profileId: '').load(), isEmpty);
   if (stall) {
    pending.complete([const PageImage('https://example.com/page.jpg')]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(await ChapterInboxStore(profileId: '').load(), isEmpty);
   }
   source.onPages = (_) async => [const PageImage('https://example.com/page.jpg')];
   // Advance only synthetic queue state to the next eligible invocation.
   await db.update('jobs', {'due': 0, 'lease': 0});
   final retry = await ChapterChecker(repository: repo, library: library).check(smartSchedule: true);
   expect(retry.discoveries, hasLength(1));
   expect((await ChapterChecker(repository: repo, library: library).check(smartSchedule: true)).discoveries, isEmpty);
   expect(await ChapterInboxStore(profileId: '').load(), hasLength(1));
  });
 }
}

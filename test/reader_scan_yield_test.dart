import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/chapter_scan_runner.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/data/reader_activity.dart';
import 'automatic_scan_reliability_test.dart' show ControlledSource;
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;
import 'chapter_checker_test.dart' show makeLibrary;

/// C1: the WorkManager engine and the app UI share the Android main thread.
/// While a reader is open, scans in any isolate must step aside promptly,
/// without counting it as a source failure or losing found chapters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cross-isolate reader marker', () {
    late Directory dir;
    var now = DateTime(2026, 11, 15, 15);
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('senreader_marker');
      now = DateTime(2026, 11, 15, 15);
    });
    tearDown(() async => dir.delete(recursive: true));
    ReaderPresenceMarker marker() => ReaderPresenceMarker(
      directory: () async => dir.path, clock: () => now);

    test('start is visible to another marker instance, stop clears it', () async {
      final reader = marker();
      final worker = marker();
      await worker.prepare();
      expect(worker.activeNow(), isFalse);
      reader.start();
      await reader.flush();
      now = now.add(const Duration(seconds: 2)); // past the 1 s re-read throttle
      expect(worker.activeNow(), isTrue);
      reader.stop();
      await reader.flush();
      now = now.add(const Duration(seconds: 2));
      expect(worker.activeNow(), isFalse);
    });

    test('a marker left by a killed process expires', () async {
      final reader = marker();
      final worker = marker();
      await worker.prepare();
      reader.start();
      await reader.flush();
      reader.stop(); // cancel heartbeat; simulate a stale file instead:
      await reader.flush();
      await File('${dir.path}${Platform.pathSeparator}senreader_reader_active')
        .writeAsString('${now.add(const Duration(seconds: 90)).millisecondsSinceEpoch}');
      now = now.add(const Duration(seconds: 2));
      expect(worker.activeNow(), isTrue);
      now = now.add(const Duration(seconds: 120));
      expect(worker.activeNow(), isFalse);
    });

    test('unknown location means not reading', () {
      expect(marker().activeNow(), isFalse);
    });
  });

  test('worker run with an open reader is skipped before any library or source work', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final runner = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
      library: library, repository: CatalogRepository(sources: {source.key: source}),
      deliver: (_) async {});
    expect(await runner.run(shouldStop: () => true), isTrue,
      reason: 'no WorkManager retry/backoff for a reader pause');
    expect(source.detailCalls, 0);
    final last = (await ChapterScanScheduleStore().lastRun(''))!;
    expect(last.outcome, 'skipped');
    expect(last.reason, 'reader_active');
  });

  test('a reader opening mid-request stops the scan at once, not as a failure', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check(); // baseline
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    await (await ChapterScanQueue().database()).update('jobs', {'due': 0});
    var reading = false;
    final pages = Completer<List<PageImage>>();
    source.onPages = (_) { reading = true; return pages.future; };
    final watch = Stopwatch()..start();
    final run = ChapterChecker(repository: repo, library: library)
      .check(smartSchedule: true, shouldStop: () => reading);
    // Even a never-answering request is abandoned: the pair slice is 45 s.
    final report = await run.timeout(const Duration(seconds: 10));
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(report.reason, 'reader_active');
    expect(report.failedSources, 0);
    expect(report.warnings, isEmpty);
    expect(await ChapterInboxStore(profileId: '').load(), isEmpty);
    pages.complete([const PageImage('https://cdn.example.com/late.jpg')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await ChapterInboxStore(profileId: '').load(), isEmpty,
      reason: 'late pages after the abort must not commit');
  });
}

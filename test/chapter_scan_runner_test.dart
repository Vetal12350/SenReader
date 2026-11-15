import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_background_scheduler.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/chapter_scan_runner.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/local_source_gate.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

class RefusingSource extends FakeSource {
  RefusingSource(this.status) : super('senkuro');
  final int status;
  @override Future<MangaDetail> detail(MangaEntry entry) =>
    LocalSourceGate.runScoped(key, () async {
      detailCalls++;
      await LocalSourceGate(key).response(status, '3600');
      throw SourceException('HTTP $status');
    });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resume catch-up does not await failed or stalled native scheduling', () async {
    final registration = Completer<void>();
    final scanning = Completer<void>();
    var scans = 0;
    final catchUp = ChapterResumeCatchUp(register: () => registration.future,
      scan: () async { scans++; await scanning.future; });
    final first = catchUp.run();
    await Future<void>.delayed(Duration.zero);
    expect(scans, 1);
    final duplicate = catchUp.run();
    expect(scans, 1);
    registration.completeError(StateError('native plugin unavailable'));
    scanning.complete();
    await Future.wait([first, duplicate]);
    await catchUp.run();
    expect(scans, 2);
  });

  for (final profile in ['', 'uid-a', 'uid-b']) {
    test('automatic discoveries persist without OS permission for profile $profile', () async {
      final prefs = MemoryAlertPreferences()..on = true;
      final source = FakeSource('senkuro')
        ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
      final library = LibraryStore();
      await library.load();
      await library.switchProfile(profile);
      final book = UnifiedManga(title: 'Example', entries: {
        source.key: const MangaEntry(source: 'senkuro', id: '1', title: 'Example'),
      });
      await library.setStatus(book, 'reading');
      await library.savePosition(book, source.chapters.single, source.key,
        pageIndex: 7, pageCount: 20);
      final repository = CatalogRepository(sources: {source.key: source});
      await ChapterChecker(repository: repository, library: library).check();
      source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
      final db = await ChapterScanQueue().database();
      await db.update('jobs', {'due': 0}); // next eligible automatic run
      var osDeliveryCalls = 0;
      final runner = ChapterScanRunner(preferences: prefs, library: library,
        repository: repository, deliver: (_) async { osDeliveryCalls++; });
      expect(await runner.run(origin: 'app'), isTrue);
      expect((await ChapterInboxStore(profileId: profile).load()).single.chapterId, '2');
      expect(osDeliveryCalls, 0);
      final summary = (await ChapterScanScheduleStore().lastRun(profile))!;
      expect(summary.outcome, 'success');
      expect(summary.checkedSources, 1);
      expect(summary.foundChapters, 1);
      for (final other in ['', 'uid-a', 'uid-b'].where((id) => id != profile)) {
        expect(await ChapterInboxStore(profileId: other).load(), isEmpty);
        expect(await ChapterScanScheduleStore().lastRun(other), isNull);
      }
      await library.load();
      expect(library.items.single.lastPageIndex, 7);
      expect(library.items.single.readChapterKeys, isEmpty);
      expect(await runner.run(), isTrue);
      expect((await ChapterScanScheduleStore().lastRun(profile))!.outcome, 'skipped');
      expect((await ChapterInboxStore(profileId: profile).load()).length, 1);
    });
  }

  test('disabled and empty runs have explicit diagnostic results', () async {
    final prefs = MemoryAlertPreferences();
    final runner = ChapterScanRunner(preferences: prefs);
    expect(await runner.run(), isTrue);
    expect((await ChapterScanScheduleStore().lastRun(''))!.reason, 'disabled');
    prefs.on = true;
    await runner.run();
    expect((await ChapterScanScheduleStore().lastRun(''))!.reason, 'no_reading');
  });

  for (final status in [403, 429]) {
    test('HTTP $status diagnostic and cooldown do not suppress the other provider', () async {
      final source = RefusingSource(status);
      final other = FakeSource('readmanga');
      final library = await makeLibrary([source, other]);
      final runner = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
        library: library, repository: CatalogRepository(sources: {
          source.key: source, other.key: other,
        }));
      expect(await runner.run(), isTrue);
      final summary = (await ChapterScanScheduleStore().lastRun(''))!;
      expect(summary.outcome, 'partial');
      expect(summary.reason, 'http_$status');
      expect(summary.checkedSources, 2);
      expect(source.detailCalls, 1);
      expect(other.detailCalls, 1);
      await runner.run();
      expect(source.detailCalls, 1); // no retry through an access restriction
      final db = await ChapterScanQueue().database();
      await db.update('jobs', {'due': 0}, where: 'source = ?', whereArgs: ['readmanga']);
      await runner.run();
      expect(other.detailCalls, 2);
      expect(source.detailCalls, 1);
    });
  }

  test('offline is partial, with a safe reason and a retryable queue', () async {
    final source = FakeSource('senkuro')..available = false;
    final library = await makeLibrary([source]);
    final runner = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
      library: library, repository: CatalogRepository(sources: {source.key: source}));
    expect(await runner.run(), isFalse);
    final summary = (await ChapterScanScheduleStore().lastRun(''))!;
    expect(summary.outcome, 'partial');
    expect(summary.reason, 'source_error');
    expect(summary.nextEligibleAt, isNotNull);
    expect(library.items.single.initializedSources, isEmpty);
    source.available = true;
    await (await ChapterScanQueue().database()).update('jobs', {'due': 0});
    await runner.run();
    expect((await ChapterScanScheduleStore().lastRun(''))!.outcome, 'success');
  });

  test('profile switch cannot deliver another profile or overwrite its diagnostic', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final runner = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
      library: library, scan: (_) async {
        await library.switchProfile('uid-b');
        return const ChapterScanReport([], [], 1, checkedSources: 1);
      });
    await runner.run();
    expect((await ChapterScanScheduleStore().lastRun(''))!.reason, 'profile_changed');
    expect(await ChapterScanScheduleStore().lastRun('uid-b'), isNull);
    expect(await ChapterInboxStore(profileId: 'uid-b').load(), isEmpty);
  });

  test('optional OS plugin failure cannot lose discoveries or the successful summary', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final prefs = MemoryAlertPreferences()..on = true..systemOn = true;
    final runner = ChapterScanRunner(preferences: prefs, library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      deliver: (_) async => throw StateError('native notification plugin'));
    expect(await runner.run(), isTrue);
    expect((await ChapterScanScheduleStore().lastRun(''))!.outcome, 'success');
  });

  test('OS opt-in with POST_NOTIFICATIONS denied still commits automatic releases', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    await (await ChapterScanQueue().database()).update('jobs', {'due': 0});
    final prefs = MemoryAlertPreferences()..on = true..systemOn = true;
    var posts = 0;
    int? postedCount;
    final runner = ChapterScanRunner(preferences: prefs, library: library,
      repository: repo, deliver: (_) async {
        postedCount = await ChapterNotificationService.instance.postNewChapters(const [],
          preferences: prefs, permissionCheck: () async => false,
          sendNotification: (_) async { posts++; });
      });
    expect(await runner.run(), isTrue);
    final inbox = ChapterInboxStore(profileId: '');
    expect((await inbox.load()).single.hidden, isFalse);
    expect((await inbox.pendingSystemNotifications()).length, 1);
    expect(posts, 0);
    expect(postedCount, 0);
    expect((await ChapterScanScheduleStore().lastRun(''))!.foundChapters, 1);
  });

  test('worker failure replaces the old success without recording private exception text', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final prefs = MemoryAlertPreferences()..on = true;
    final runner = ChapterScanRunner(preferences: prefs, library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      scan: (_) async => throw StateError('private title / token'));
    expect(await runner.run(), isFalse);
    final summary = (await ChapterScanScheduleStore().lastRun(''))!;
    expect(summary.outcome, 'error');
    expect(summary.reason, 'scan_error');
    final raw = (await (await ChapterScanQueue().database()).query('scan_runs'))
        .single['payload'] as String;
    expect(raw, isNot(contains('private')));
  });

  test('running record survives interruption and is replaced on retry', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final paused = Completer<ChapterScanReport>();
    final runner = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
      library: library, scan: (_) => paused.future);
    final result = runner.run();
    while ((await ChapterScanScheduleStore().lastRun(''))?.outcome != 'running') {
      await Future<void>.delayed(Duration.zero);
    }
    expect((await ChapterScanScheduleStore().lastRun(''))!.checkedSources, 0);
    paused.completeError(StateError('isolate stopped'));
    expect(await result, isFalse);
    expect((await ChapterScanScheduleStore().lastRun(''))!.outcome, 'error');
  });

  for (final count in [70, 200]) {
    test('$count titles: bounded runs resume, both providers reach inbox without OS', () async {
      final a = FakeSource('senkuro')
        ..chapters = [const Chapter(id: 's2', name: 'Глава 2')];
      final b = FakeSource('readmanga')
        ..chapters = [const Chapter(id: 'r2', name: 'Глава 2')];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(LibraryStore.storageKey, jsonEncode([
        for (var i = 0; i < count; i++) SavedBook(title: 'Book $i',
          status: 'reading', initializedSources: {a.key, b.key}, entries: {
            for (final s in [a, b]) s.key: MangaEntry(source: s.key,
              id: '$i', title: 'Book $i'),
          }).toJson(),
      ]));
      final original = prefs.getString(LibraryStore.storageKey);
      final library = LibraryStore();
      await library.load();
      for (final book in library.items) {
        for (final source in [a, b]) {
          await ChapterInboxStore(profileId: '').recordScan(
            book.key, source.key, book.entries[source.key]!.id, ['v0:c1'], {});
        }
      }
      final repo = CatalogRepository(sources: {a.key: a, b.key: b});
      var pairs = 0;
      final first = await ChapterChecker(repository: repo, library: library,
        elapsed: () => Duration(seconds: pairs), afterPair: () async { pairs++; })
          .check(smartSchedule: true, budget: const Duration(seconds: 17));
      expect(first.checkedSources, 17);
      expect((a.detailCalls - b.detailCalls).abs(), lessThanOrEqualTo(1));
      final rest = await ChapterChecker(repository: repo, library: library)
          .check(smartSchedule: true);
      expect(rest.checkedSources, count * 2 - 17);
      expect((await ChapterInboxStore(profileId: '').load()).length, count);
      expect(await ChapterInboxStore(profileId: 'uid-a').load(), isEmpty);
      expect(a.detailCalls, count);
      expect(b.detailCalls, count);
      await prefs.reload();
      expect(prefs.getString(LibraryStore.storageKey), original);
      expect((await ChapterChecker(repository: repo, library: library)
        .check(smartSchedule: true)).checkedSources, 0);
    });
  }
}

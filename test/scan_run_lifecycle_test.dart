import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/chapter_scan_runner.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/data/library_store.dart';
import 'automatic_scan_reliability_test.dart' show ControlledSource;
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;
import 'chapter_checker_test.dart' show makeLibrary;

ChapterBackgroundScanSummary summary(DateTime at, {int id = 0,
    String origin = 'workmanager', String outcome = 'running', int found = 0,
    DateTime? finishedAt}) => ChapterBackgroundScanSummary(at: at, runId: id,
  origin: origin, outcome: outcome, foundChapters: found, checkedSources: found,
  skippedSources: 0, warnings: 0, finishedAt: finishedAt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final profile in ['', 'uid-a', 'uid-b']) {
    test('fresh run is running, expiry preserves checkpoints and fences late owner: $profile', () async {
      var now = DateTime(2026, 11, 3, 16, 5, 13);
      final store = ChapterScanScheduleStore(clock: () => now);
      final start = now;
      final id = await store.beginRun(profile, summary(start));
      now = now.add(const Duration(seconds: 32)); // screenshot in the same minute
      expect((await store.lastRun(profile))!.outcome, 'running');
      expect((await store.lastRun(profile))!.finishedAt, isNull);
      await store.recordRun(profile, summary(start, id: id, found: 2));
      now = now.add(const Duration(minutes: 4));
      final interrupted = (await store.lastRun(profile))!;
      expect(interrupted.outcome, 'interrupted');
      expect(interrupted.foundChapters, 2);
      expect(interrupted.finishedAt, isNull);
      await store.recordRun(profile, summary(start, id: id, outcome: 'success', found: 99));
      expect((await store.lastRun(profile))!.outcome, 'interrupted');
      expect((await store.lastRun(profile))!.foundChapters, 2);
      for (final other in ['', 'uid-a', 'uid-b'].where((p) => p != profile)) {
        expect(await store.lastRun(other), isNull);
      }
    });
  }

  test('same-timestamp overlapping runs keep separate origins and monotonic identities', () async {
    final at = DateTime.now();
    final store = ChapterScanScheduleStore();
    final old = await store.beginRun('', summary(at));
    final current = await store.beginRun('', summary(at));
    final app = await store.beginRun('', summary(at, origin: 'app'));
    await store.recordRun('', summary(at, id: current, outcome: 'success', found: 3, finishedAt: at));
    await store.recordRun('', summary(at, id: old, found: 1));
    await store.recordRun('', summary(at, id: app, origin: 'app', outcome: 'skipped', finishedAt: at));
    expect((await store.lastRun('', workmanagerOnly: true))!.runId, current);
    expect((await store.lastRun('', workmanagerOnly: true))!.foundChapters, 3);
    expect((await store.lastRun('', appOnly: true))!.runId, app);
    // A late running checkpoint cannot reopen an already completed attempt.
    await store.recordRun('', summary(at, id: current, found: 0));
    expect((await store.lastRun('', workmanagerOnly: true))!.outcome, 'success');
  });

  test('foreground catch-up and worker compete safely without erasing either report', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    await (await ChapterScanQueue().database()).update('jobs', {'due': 0});
    final started = Completer<void>();
    final pages = Completer<List<PageImage>>();
    source.onPages = (_) { if (!started.isCompleted) started.complete(); return pages.future; };
    final prefs = MemoryAlertPreferences()..on = true;
    final app = ChapterScanRunner(preferences: prefs, library: library, repository: repo).run(origin: 'app');
    await started.future;
    await ChapterScanRunner(preferences: prefs, library: LibraryStore(), repository: repo).run();
    final store = ChapterScanScheduleStore();
    expect((await store.lastRun('', workmanagerOnly: true))!.reason, 'lease');
    expect((await store.lastRun('', workmanagerOnly: true))!.checkedSources, 0);
    expect((await store.lastRun('', appOnly: true))!.outcome, 'running');
    expect((await store.lastRun('', appOnly: true))!.availableSources, 1);
    pages.complete([const PageImage('https://cdn.example.com/2.jpg')]);
    expect(await app, isTrue);
    expect((await store.lastRun('', appOnly: true))!.foundChapters, 1);
    expect((await store.lastRun('', appOnly: true))!.duration, isNotNull);
    expect((await store.lastRun('', workmanagerOnly: true))!.reason, 'lease');
    expect((await ChapterInboxStore(profileId: '').load()).length, 1);
  });

  test('a timed-out pair keeps its lease and late pages cannot commit or become success', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    final db = await ChapterScanQueue().database();
    await db.update('jobs', {'due': 0});
    final started = Completer<void>();
    final pending = Completer<List<PageImage>>();
    source.onPages = (_) { if (!started.isCompleted) started.complete(); return pending.future; };
    final run = ChapterChecker(repository: repo, library: library,
      sourceSlice: const Duration(milliseconds: 150)).check(smartSchedule: true);
    await started.future;
    final report = await run;
    expect(report.reason, 'timeout');
    expect(report.successfulSources, 0);
    expect(report.failedSources, 1);
    final leased = (await db.query('jobs')).single;
    expect(leased['lease'] as int, greaterThan(DateTime.now().millisecondsSinceEpoch));
    pending.complete([const PageImage('https://cdn.example.com/late.jpg')]);
    // Allow the real filesystem futures of the uncancelled child to settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await ChapterInboxStore(profileId: '').load(), isEmpty);
    await library.load();
    expect(library.items.single.seenChapterKeys, isNot(contains('v0:c2')));
    expect((await db.query('jobs')).single['lease'], leased['lease']);
  });

  test('a running baseline reports its durable release before its second pages request ends', () async {
    final date = DateTime.now().subtract(const Duration(hours: 1));
    final source = ControlledSource('senkuro')..chapters = [
      Chapter(id: '3', name: 'Глава 3', publishedAt: date),
      Chapter(id: '2', name: 'Глава 2', publishedAt: date),
      const Chapter(id: '1', name: 'Глава 1'),
    ];
    final library = await makeLibrary([source]);
    await library.markRead(library.items.single.toUnified(), source.chapters.last, source.key);
    final second = Completer<List<PageImage>>();
    final started = Completer<void>();
    source.onPages = (chapter) {
      if (chapter.id == '2') { started.complete(); return second.future; }
      return Future.value([const PageImage('https://cdn.example.com/3.jpg')]);
    };
    final run = ChapterScanRunner(preferences: MemoryAlertPreferences()..on = true,
      library: library, repository: CatalogRepository(sources: {source.key: source})).run(origin: 'app');
    await started.future;
    final snapshot = (await ChapterScanScheduleStore().lastRun('', appOnly: true))!;
    second.complete([const PageImage('https://cdn.example.com/2.jpg')]);
    expect(await run, isTrue);
    expect(snapshot.outcome, 'running');
    expect(snapshot.foundChapters, 1);
    expect(snapshot.availableSources, 1);
    expect((await ChapterInboxStore(profileId: '').load()).length, 2);
    expect((await ChapterScanScheduleStore().lastRun('', appOnly: true))!.foundChapters, 2);
  });

  test('queue v1 upgrade preserves existing jobs, fencing and provider cooldown; inbox remains v4', () async {
    final original = ChapterInboxStore.databasePathOverride!;
    final path = '$original.migration.queue';
    final legacy = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('CREATE TABLE jobs (profile TEXT, key TEXT, book TEXT, source TEXT, '
        'sourceId TEXT, due INTEGER DEFAULT 0, turn INTEGER DEFAULT 0, lease INTEGER DEFAULT 0, '
        'token INTEGER DEFAULT 0, PRIMARY KEY(profile,key))');
      await db.execute('CREATE TABLE providers (source TEXT PRIMARY KEY, next INTEGER DEFAULT 0, '
        'lease INTEGER DEFAULT 0, token INTEGER DEFAULT 0)');
    });
    final key = ScanJob('old', 'senkuro', 'original-source-id').key;
    await legacy.insert('jobs', {'profile': 'uid-a', 'key': key, 'book': 'old',
      'source': 'senkuro', 'sourceId': 'original-source-id', 'due': 123, 'turn': 456,
      'lease': 789, 'token': 7});
    await legacy.insert('providers', {'source': 'senkuro', 'next': 9999999999999, 'lease': 321, 'token': 9});
    final jobs = await legacy.query('jobs');
    final providers = await legacy.query('providers');
    await legacy.close();
    ChapterInboxStore.databasePathOverride = '$original.migration';
    try {
      final upgraded = await ChapterScanQueue().database();
      expect(await upgraded.getVersion(), 2);
      expect(await upgraded.query('jobs'), jobs);
      expect(await upgraded.query('providers'), providers);
      expect(await upgraded.query('scan_runs'), isEmpty);
      await upgraded.close();
    } finally { ChapterInboxStore.databasePathOverride = original; }
    expect(await (await openDatabase(original)).getVersion(), 4);
  });

  test('legacy diagnostic survives upgrade without changing library or inventing an end time', () async {
    final prefs = await SharedPreferences.getInstance();
    const library = '[{"title":"untouched"}]';
    await prefs.setString(LibraryStore.storageKey, library);
    await prefs.setString('senreader.chapter_scan_last.v1.guest', jsonEncode({
      'at': DateTime.now().millisecondsSinceEpoch, 'checked': 2, 'found': 1,
      'warnings': 0, 'origin': 'workmanager', 'outcome': 'success',
    }));
    final last = (await ChapterScanScheduleStore().lastRun('', workmanagerOnly: true))!;
    expect(last.checkedSources, 2);
    expect(last.finishedAt, isNull);
    expect(last.duration, isNull);
    expect(prefs.getString(LibraryStore.storageKey), library);
  });

  test('SQLite bootstrap failure remains visible through preferences with separate origins', () async {
    final store = ChapterScanScheduleStore(database: () async => throw StateError('SQLite plugin unavailable'));
    final now = DateTime.now();
    await store.recordBootstrapFailure('', ChapterBackgroundScanSummary(at: now,
      checkedSources: 0, skippedSources: 0, foundChapters: 0, warnings: 1,
      outcome: 'error', reason: 'plugin_error', finishedAt: now));
    await store.recordBootstrapFailure('', ChapterBackgroundScanSummary(at: now,
      origin: 'app', checkedSources: 0, skippedSources: 0, foundChapters: 0, warnings: 1,
      outcome: 'error', reason: 'scan_error', finishedAt: now));
    expect((await store.lastRun('', workmanagerOnly: true))!.reason, 'plugin_error');
    expect((await store.lastRun('', appOnly: true))!.reason, 'scan_error');
    expect(await store.lastRun('uid-a'), isNull);
    expect((await ChapterScanScheduleStore().lastRun('', workmanagerOnly: true))!.reason, 'plugin_error');
  });
}

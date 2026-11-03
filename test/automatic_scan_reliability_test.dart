import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

class ControlledSource extends FakeSource {
  ControlledSource(super.key);
  void Function()? onDetail;
  Future<List<PageImage>> Function(Chapter)? onPages;
  @override Future<MangaDetail> detail(MangaEntry entry) async {
    final value = await super.detail(entry);
    onDetail?.call();
    return value;
  }
  @override Future<List<PageImage>> pages(Chapter chapter) =>
      onPages?.call(chapter) ?? super.pages(chapter);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('budget expiry after detail cannot become a successful 30 minute checkpoint', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    final db = await ChapterScanQueue().database();
    await db.update('jobs', {'due': 0});
    var spent = Duration.zero;
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    source.onDetail = () { spent = const Duration(seconds: 121); };
    final report = await ChapterChecker(repository: repo, library: library,
      elapsed: () => spent).check(smartSchedule: true);
    expect(report.warnings, isNotEmpty);
    expect(report.reason, 'timeout');
    final row = (await db.query('jobs')).single;
    expect(row['due'] as int, lessThan(DateTime.now().add(const Duration(minutes: 6)).millisecondsSinceEpoch));
    expect((await ChapterInboxStore(profileId: '').load()), isEmpty);
    source.onDetail = null;
    await db.update('jobs', {'due': 0, 'lease': 0});
    final retry = await ChapterChecker(repository: repo, library: library).check(smartSchedule: true);
    expect(retry.discoveries.single.chapter.id, '2');
  });

  test('empty pages leave the release unseen and report an incomplete source', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters.add(const Chapter(id: '2', name: 'Глава 2'));
    source.onPages = (_) async => [];
    await (await ChapterScanQueue().database()).update('jobs', {'due': 0});
    final result = await ChapterChecker(repository: repo, library: library).check(smartSchedule: true);
    expect(result.warnings, isNotEmpty);
    expect(library.items.single.seenChapterKeys, isNot(contains('v0:c2')));
  });

  test('a silent baseline in the other translation cannot swallow a later preferred release', () async {
    final a = FakeSource('senkuro')..chapters = [const Chapter(id: 's1', name: 'Глава 1')];
    final b = FakeSource('readmanga')..chapters = [const Chapter(id: 'r5', name: 'Глава 5')];
    final library = await makeLibrary([a, b]);
    final repo = CatalogRepository(sources: {a.key: a, b.key: b});
    final checker = ChapterChecker(repository: repo, library: library);
    await checker.check();
    final prefs = await SharedPreferences.getInstance();
    final original = prefs.getString('senreader.library.v1');
    a.chapters = [const Chapter(id: 's5-new-slug', name: 'Глава 5: Другой перевод')];
    final result = await checker.check();
    expect(result.discoveries.map((d) => d.chapter.id), ['s5-new-slug']);
    expect((await ChapterInboxStore(profileId: '').load()).length, 1);
    expect((await checker.check()).discoveries, isEmpty);
    await prefs.reload();
    expect(prefs.getString('senreader.library.v1'), original);
    expect(library.items.single.readChapterKeys, isEmpty);
  });

  test('baseline checkpoints its first verified release before the next page request', () async {
    final now = DateTime.now();
    final source = ControlledSource('senkuro')..chapters = [
      Chapter(id: '3', name: 'Глава 3', publishedAt: now.subtract(const Duration(hours: 1))),
      Chapter(id: '2', name: 'Глава 2', publishedAt: now.subtract(const Duration(hours: 2))),
      const Chapter(id: '1', name: 'Глава 1'),
    ];
    final library = await makeLibrary([source]);
    await library.markRead(library.items.single.toUnified(), source.chapters.last, source.key);
    final pending = Completer<List<PageImage>>();
    final started = Completer<void>();
    source.onPages = (chapter) async {
      if (chapter.id == '2') { started.complete(); return pending.future; }
      return [const PageImage('https://cdn.example.com/page.jpg')];
    };
    final run = ChapterChecker(repository: CatalogRepository(sources: {source.key: source}),
      library: library).check();
    await started.future;
    final checkpoint = await ChapterInboxStore(profileId: '').load();
    pending.complete([const PageImage('https://cdn.example.com/2.jpg')]);
    await run;
    expect(checkpoint.map((row) => row.chapterId), contains('3'));
  });

  test('unrecognized nonempty chapter metadata is not a successful empty baseline', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 'special', name: 'Special release')];
    final library = await makeLibrary([source]);
    final result = await ChapterChecker(repository: CatalogRepository(sources: {source.key: source}),
      library: library).check();
    expect(result.warnings, isNotEmpty);
    expect(library.items.single.initializedSources, isEmpty);
  });

  test('a late old worker checkpoint cannot overwrite a newer worker result', () async {
    final store = ChapterScanScheduleStore();
    final old = DateTime(2026, 11, 3, 16, 5, 13);
    final recent = old.add(const Duration(minutes: 10));
    await store.recordRun('', ChapterBackgroundScanSummary(at: recent,
      checkedSources: 3, skippedSources: 0, foundChapters: 2, warnings: 0));
    await store.recordRun('', ChapterBackgroundScanSummary(at: old,
      checkedSources: 0, skippedSources: 0, foundChapters: 0, warnings: 0, outcome: 'running'));
    expect((await store.lastRun('', workmanagerOnly: true))!.at, recent);
    expect((await store.lastRun(''))!.outcome, 'success');
  });

  test('provider lease is skipped before claiming more books on the same provider', () async {
    final queue = ChapterScanQueue();
    await queue.reconcile('', [ScanJob('example', 'senkuro', '1')]);
    final db = await queue.database();
    const now = 1000000;
    await db.insert('providers', {'source': 'senkuro', 'lease': now + 60000});
    expect(await queue.claim('', 'senkuro', now), isNull);
    expect((await queue.status('', now)).reason, 'lease');
    expect(await queue.claim('', 'senkuro', now + 60001), isNotNull);
  });

  test('new unseen releases are verified before optional recovery of legacy seen releases', () async {
    final source = ControlledSource('senkuro');
    final library = await makeLibrary([source]);
    final first = const Chapter(id: '1', name: 'Глава 1');
    final book = library.items.single.toUnified();
    await library.markRead(book, first, source.key);
    await library.recordChapterScan(library.items.single.key, source.key,
      ['v0:c1', 'v0:c2', 'v0:c3']);
    final date = DateTime.now().subtract(const Duration(hours: 1));
    source.chapters = [const Chapter(id: '4', name: 'Глава 4'),
      Chapter(id: '3', name: 'Глава 3', publishedAt: date),
      Chapter(id: '2', name: 'Глава 2', publishedAt: date), first];
    final calls = <String>[];
    source.onPages = (chapter) async {
      calls.add(chapter.id);
      return [const PageImage('https://cdn.example.com/page.jpg')];
    };
    await ChapterChecker(repository: CatalogRepository(sources: {source.key: source}),
      library: library).check();
    expect(calls.first, '4', reason: 'legacy recovery must not consume the entire slice before a new release');
    expect((await ChapterInboxStore(profileId: '').load()).length, 3);
  });

  test('partial burst, missed interval, hidden replay and denied Android permission retain every update', () async {
    final source = ControlledSource('senkuro')
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    final checker = ChapterChecker(repository: repo, library: library,
      systemNotificationsEnabled: true);
    await checker.check();
    final prefs = await SharedPreferences.getInstance();
    final original = prefs.getString(LibraryStore.storageKey);
    final old = DateTime.now().subtract(const Duration(days: 7));
    source.chapters.addAll([for (var n = 2; n <= 4; n++)
      Chapter(id: '$n', name: 'Глава $n', publishedAt: old)]);
    source.onPages = (chapter) async {
      if (chapter.id == '3') throw TimeoutException('temporary CDN timeout');
      return [const PageImage('https://cdn.example.com/page.jpg')];
    };
    final db = await ChapterScanQueue().database();
    await db.update('jobs', {'due': 0});
    final report = await checker.check(smartSchedule: true);
    expect(report.discoveries.map((d) => d.chapter.id), ['2', '4']);
    expect(report.failedSources, 1);
    expect(report.successfulSources, 0);
    final inbox = ChapterInboxStore(profileId: '');
    final fourth = (await inbox.load()).singleWhere((row) => row.chapterId == '4');
    await inbox.hideEntry(fourth.key);
    source.onPages = null;
    source.chapters.add(Chapter(id: '5.50-new-id', name: 'Глава 5.5', publishedAt: old));
    await db.update('jobs', {'due': 0}); // Android did not run during the interval
    final next = await checker.check(smartSchedule: true);
    expect(next.discoveries.map((d) => d.canonicalKey), ['v0:c3', 'v0:c5.5']);
    expect((await inbox.load()).length, 4);
    expect((await inbox.load()).singleWhere((row) => row.chapterId == '4').hidden, isTrue);
    final settings = MemoryAlertPreferences()..on = true..systemOn = true;
    var systemPosts = 0;
    expect(await ChapterNotificationService.instance.postNewChapters(const [],
      preferences: settings, permissionCheck: () async => false,
      sendNotification: (_) async { systemPosts++; }), 0);
    expect(systemPosts, 0);
    expect((await inbox.pendingSystemNotifications()).length, 3);
    expect((await checker.check(smartSchedule: true)).checkedSources, 0);
    await prefs.reload();
    expect(prefs.getString(LibraryStore.storageKey), original);
    expect(library.items.single.readChapterKeys, isEmpty);
  });

  test('deferred baseline releases remain discoverable after the 36 hour window', () async {
    final source = ControlledSource('senkuro');
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    const first = Chapter(id: '1', name: 'Глава 1');
    await library.markRead(book, first, source.key);
    final recent = DateTime.now().subtract(const Duration(hours: 1));
    source.chapters = [for (var n = 5; n >= 2; n--)
      Chapter(id: '$n', name: 'Глава $n', publishedAt: recent), first];
    final checker = ChapterChecker(repository: CatalogRepository(sources: {source.key: source}), library: library);
    final initial = await checker.check();
    expect(initial.discoveries.map((d) => d.chapter.id), ['5', '4']);
    expect(initial.chapterDecisions['verification_deferred'], 2);
    source.chapters = [for (var n = 5; n >= 2; n--)
      Chapter(id: '$n', name: 'Глава $n', publishedAt: recent.subtract(const Duration(days: 3))), first];
    final next = await checker.check();
    expect(next.discoveries.map((d) => d.chapter.id), ['3', '2']);
    expect((await ChapterInboxStore(profileId: '').load()).length, 4);
  });
}

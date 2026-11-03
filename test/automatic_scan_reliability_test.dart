import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
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
}

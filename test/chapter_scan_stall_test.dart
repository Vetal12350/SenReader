import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_scan_runner.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

class StalledSource extends FakeSource {
  StalledSource() : super('senkuro');
  bool stalled = true;
  final pending = Completer<MangaDetail>();
  @override
  Future<MangaDetail> detail(MangaEntry entry) =>
      stalled ? pending.future : super.detail(entry);
}

void main() {
  test('manual source never replies: existing timeout returns, then retry succeeds', () async {
    final source = StalledSource()
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final runner = ChapterScanRunner(library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      preferences: MemoryAlertPreferences());
    final watch = Stopwatch()..start();
    final report = await runner.checkManual();
    expect(report.reason, 'timeout');
    expect(report.warnings, hasLength(1));
    expect(watch.elapsed, lessThan(const Duration(seconds: 25)));
    expect(await ChapterInboxStore(profileId: '').loadScanState(), isEmpty);
    source.stalled = false;
    final retry = await runner.checkManual();
    expect(retry.warnings, isEmpty);
    expect(retry.checkedSources, 1);
    expect(retry.discoveries, isEmpty); // First successful snapshot is silent.
    // Release the synthetic request without touching any device/source.
    source.pending.complete(await source.detail(source.entry));
  });

  test('scheduled stalled source returns at slice budget without successful baseline', () async {
    final source = StalledSource();
    final library = await makeLibrary([source]);
    final report = await ChapterChecker(library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      sourceSlice: const Duration(milliseconds: 30))
      .check(smartSchedule: true, budget: const Duration(milliseconds: 100));
    expect(report.failedSources, 1);
    expect(report.successfulSources, 0);
    expect(await ChapterInboxStore(profileId: '').loadScanState(), isEmpty);
    source.stalled = false;
    source.pending.complete(await source.detail(source.entry));
    // Let the expired child observe its deadline before the temporary DB closes.
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/release_cadence.dart';
import 'automatic_scan_reliability_test.dart' show ControlledSource;
import 'chapter_checker_test.dart' show makeLibrary;

/// Check a title often around its expected next release, rarely otherwise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const cadence = ReleaseCadence();
  // Weekly releases on Mondays (UTC), last one on 2026-11-09.
  final weekly = [for (var i = 0; i < 8; i++)
    DateTime.utc(2026, 11, 9).subtract(Duration(days: 7 * i))];

  test('weekly rhythm is recognised; same-day batches count once', () {
    expect(cadence.interval(weekly), const Duration(days: 7));
    expect(cadence.interval([...weekly, DateTime.utc(2026, 11, 9, 18)]),
      const Duration(days: 7));
  });

  test('right after a release: long pause, bounded by the safety net', () {
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 11, 10, 12)),
      const Duration(hours: 12));
  });

  test('pause ends when the release window opens (a day before)', () {
    // Window opens 2026-11-15 00:00 UTC; 5 h before that → wait 5 h.
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 11, 14, 19)),
      const Duration(hours: 5));
  });

  test('inside the release window: check every run', () {
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 11, 15, 8)),
      const Duration(minutes: 30));
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 11, 16, 20)),
      const Duration(minutes: 30));
  });

  test('late release: every 3 h; long hiatus: safety pace', () {
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 11, 19)),
      const Duration(hours: 3));
    expect(cadence.nextDelay(weekly, DateTime.utc(2026, 12, 10)),
      const Duration(hours: 12));
  });

  test('unknown or irregular rhythm keeps the old 30 min interval', () {
    final now = DateTime.utc(2026, 11, 17);
    expect(cadence.nextDelay(weekly.take(3), now), const Duration(minutes: 30));
    final irregular = [DateTime.utc(2026, 11, 1), DateTime.utc(2026, 11, 2),
      DateTime.utc(2026, 11, 12), DateTime.utc(2026, 11, 13), DateTime.utc(2026, 10, 1),
      DateTime.utc(2026, 10, 25)];
    expect(cadence.interval(irregular), isNull);
    expect(cadence.nextDelay(irregular, now), const Duration(minutes: 30));
  });

  test('a successful scheduled check of a weekly title pauses its queue job', () async {
    final now = DateTime.now();
    // Weekly releases, the latest one yesterday: next due in ~5 days.
    final source = ControlledSource('readmanga')..chapters = [
      for (var i = 0; i < 6; i++)
        Chapter(id: '${6 - i}', name: 'Глава ${6 - i}',
          publishedAt: now.subtract(Duration(days: 1 + 7 * i))),
    ];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check(); // baseline + dates
    final db = await ChapterScanQueue().database();
    await db.update('jobs', {'due': 0, 'lease': 0});
    final report = await ChapterChecker(repository: repo, library: library)
      .check(smartSchedule: true);
    expect(report.chapterDecisions['cadence_paused'], 1);
    final due = (await db.query('jobs')).single['due'] as int;
    final pause = Duration(milliseconds: due - now.millisecondsSinceEpoch);
    expect(pause, greaterThan(const Duration(hours: 11)));
    expect(pause, lessThan(const Duration(hours: 13)));
  });
}

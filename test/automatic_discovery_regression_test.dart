import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('successful manual scan postpones an already queued overdue pair', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source,
    }), library: library);
    final saved = library.items.single;
    await ChapterScanQueue().reconcile('', [ScanJob(saved.key, source.key, '1')]);
    await checker.check();
    final auto = await checker.check(smartSchedule: true);
    expect(auto.checkedSources, 0,
      reason: 'manual success must respect the 30-minute interval for existing jobs too');
    expect(source.detailCalls, 1);
  });

  test('failed manual scan does not suppress automatic retry for 30 minutes', () async {
    final source = FakeSource('senkuro')..available = false;
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {
      source.key: source,
    }), library: library);
    expect((await checker.check()).warnings, isNotEmpty);
    final db = await ChapterScanQueue().database();
    // Six minutes after a failed attempt: normal retry is five minutes.
    final sixMinutesAgo = DateTime.now().subtract(const Duration(minutes: 6))
        .millisecondsSinceEpoch;
    final key = ChapterScanPolicy.keyFor(library.items.single, source.key, '1');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('senreader.chapter_scan_schedule.v1.guest',
        jsonEncode({key: sixMinutesAgo}));
    // A fixed implementation checkpoints manual failures into the durable queue.
    await db.update('jobs', {'due': sixMinutesAgo + 300000});
    source.available = true;
    source.chapters = [const Chapter(id: '1', name: 'Глава 1')];
    expect((await checker.check(smartSchedule: true)).checkedSources, 1);
    expect(library.items.single.readChapterKeys, isEmpty);
  });

  test('manual success during a worker lease survives its failed completion', () async {
    final queue = ChapterScanQueue();
    final job = ScanJob('example', 'senkuro', '1');
    await queue.reconcile('a', [job]);
    final lease = (await queue.claim('a', 'senkuro', 1000))!;
    await queue.recordManualAttempt('a', job, 2000, success: true);
    await queue.recordManualAttempt('a', job, 3000, success: false);
    await queue.finish('a', lease, 4000, success: false);
    expect(await queue.claim('a', 'senkuro', 310000), isNull);
    expect(await queue.claim('a', 'senkuro', 1802000), isNotNull);
    expect(await queue.claim('b', 'senkuro', 1802000), isNull);
  });
}

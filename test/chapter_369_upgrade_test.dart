import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:sqflite/sqflite.dart';

import 'chapter_checker_test.dart' show FakeSource, makeLibrary;
import 'chapter_delivery_regression_test.dart' show InAppOnlyPreferences;

class PausedDetailSource extends FakeSource {
  PausedDetailSource() : super('senkuro');
  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<MangaDetail> detail(MangaEntry record) async {
    started.complete();
    await resume.future;
    return super.detail(record);
  }
}

void main() {
  test('368 baseline and delivered chapter ID survive 369 scan and reopen', () async {
    final source = FakeSource('senkuro')..chapters = const [
      Chapter(id: 'old', name: 'Глава 1'),
      Chapter(id: 'delivered', name: 'Глава 2.1'),
      Chapter(id: 'fresh', name: 'Глава 3'),
    ];
    final library = await makeLibrary([source]);
    final inbox = ChapterInboxStore(profileId: '');
    final db = await openDatabase(ChapterInboxStore.databasePathOverride!);
    await db.insert('scan_state', {'profile': '', 'book': 'example',
      'source': 'senkuro', 'sourceId': '1',
      'payload': jsonEncode({'seen': ['v0:c1', 'v0:c2'], 'dates': {}})});
    const previous = Chapter(id: 'delivered', name: 'Глава 2');
    await inbox.add('example', 'Example', '', 'senkuro', previous,
      sourceId: '1', systemPending: true);
    expect(await inbox.claimSystemNotification('example', previous, 'senkuro'), isTrue);

    final repo = CatalogRepository(sources: {source.key: source});
    final report = await ChapterChecker(repository: repo, library: library,
      systemNotificationsEnabled: true).check();
    expect(report.discoveries.map((d) => d.chapter.id), ['fresh']);
    expect((await inbox.pendingSystemNotifications()).map((e) => e.chapterId), ['fresh']);
    await db.close();
    await library.load();
    expect((await ChapterChecker(repository: repo, library: library).check()).discoveries,
      isEmpty);
  });

  test('manual scan skips a pair while the background scan holds its lease', () async {
    final source = PausedDetailSource();
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    final worker = ChapterChecker(repository: repo, library: library)
        .check(smartSchedule: true);
    await source.started.future;
    try {
      final manual = await ChapterChecker(repository: repo, library: library).check();
      expect(manual.checkedSources, 0);
      expect(manual.skippedSources, 1);
    } finally {
      source.resume.complete();
      await worker;
    }
    expect(source.detailCalls, 1);
  });

  test('an active chapter lease leaves other chapter notifications independent', () async {
    final source = FakeSource('senkuro');
    await makeLibrary([source]);
    final inbox = ChapterInboxStore(profileId: '');
    for (var n = 1; n <= 3; n++) {
      await inbox.add('example', 'Example', '', 'senkuro',
        Chapter(id: '$n', name: 'Глава $n'), sourceId: '1', systemPending: true);
    }
    final first = (await inbox.pendingSystemNotifications()).first;
    final lease = (await inbox.beginSystemDelivery(first))!;
    final batches = <int>[];
    Future<int> drain() => ChapterNotificationService.instance.postNewChapters(const [],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (release) async { batches.add(release.chapterCount); });
    expect(await drain(), 2);
    await inbox.finishSystemDelivery(first, lease, delivered: false);
    expect((await Future.wait([drain(), drain()])).reduce((a, b) => a + b), 1);
    expect(batches, [1, 1, 1]);
    expect(await drain(), 0);
  });
}

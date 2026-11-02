import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;
import 'chapter_delivery_regression_test.dart' show InAppOnlyPreferences, PausingSource;

class CountingLibrary extends LibraryStore {
  int loads = 0;
  @override Future<void> load() async { loads++; await super.load(); }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v2 unclaimed historical inbox is not an OS delivery queue after upgrade', () async {
    await makeLibrary([FakeSource('senkuro')]);
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final old = await openDatabase(path, version: 2, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, identity TEXT NOT NULL, '
        'payload TEXT NOT NULL, systemClaimed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(profile,identity))');
      await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
      await db.execute('CREATE TABLE scan_state (profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
      await db.insert('migration', {'id': 'legacy-v1'});
      for (var n = 1; n <= 100; n++) {
        final entry = InboxEntry(key: 'example|senkuro|v0:c$n', bookKey: 'example',
          title: 'Example', coverUrl: '', source: 'senkuro', chapterId: '$n',
          chapterName: 'Глава $n', createdAt: n);
        await db.insert('inbox', {'profile': '', 'identity': 'example|v0:c$n',
          'payload': jsonEncode(entry.toJson()), 'systemClaimed': 0});
      }
    });
    await old.close();
    var sends = 0;
    final count = await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async { sends++; });
    expect(count, 0);
    expect(sends, 0);
    expect((await ChapterInboxStore().load()).length, 100);
  });
  test('old opt-out rows are not sent on opt-in and new releases are bounded', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    final store = ChapterInboxStore();
    for (var n = 1; n <= 100; n++) {
      await store.add('example', 'Example', '', 'senkuro', Chapter(id: '$n', name: 'Глава $n'));
    }
    final releases = [for (var n = 101; n <= 125; n++) ChapterDiscovery(
      book: library.items.single.toUnified(), sourceKey: 'senkuro', profileId: '',
      chapter: Chapter(id: '$n', name: 'Глава $n'), canonicalKey: 'v0:c$n')];
    Future<int> deliver(List<ChapterDiscovery> fresh) =>
      ChapterNotificationService.instance.postNewChapters(fresh,
        preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
        sendNotification: (d) async { expect(int.parse(d.chapter.id), greaterThan(100)); });
    expect(await deliver(releases), 10);
    expect(await deliver([]), 10);
    expect(await deliver([]), 5);
    expect(await deliver([]), 0);
  });
  for (final readFirst in [true, false]) {
    test('read-vs-inbox ordering readFirst=$readFirst does not leave unread alert', () async {
      final source = PausingSource()..chapters = [const Chapter(id: '1', name: 'Глава 1')];
      final worker = await makeLibrary([source]);
      final repo = CatalogRepository(sources: {source.key: source});
      await ChapterChecker(repository: repo, library: worker).check();
      source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
      source.paused = Completer<void>(); source.resume = Completer<void>();
      final scan = ChapterChecker(repository: repo, library: worker).check();
      await source.paused!.future;
      final reader = LibraryStore(); await reader.load();
      final book = reader.items.single.toUnified();
      if (!readFirst) { source.resume!.complete(); await scan; }
      await reader.markRead(book, source.chapters.single, source.key);
      if (readFirst) { source.resume!.complete(); await scan; }
      expect((await ChapterInboxStore().load()).where((e) => !e.hidden), isEmpty);
      await reader.load();
      expect(reader.isChapterRead(book, source.chapters.single, source.key), isTrue);
    });
  }
  test('large inbox does one library load and returns at most ten pending records', () async {
    await makeLibrary([FakeSource('senkuro')]);
    final store = ChapterInboxStore();
    for (var n = 1; n <= 200; n++) {
      final ch = Chapter(id: '$n', name: 'Глава $n');
      await store.add('example', 'Example', '', 'senkuro', ch);
      await store.claimSystemNotification('example', ch, 'senkuro');
    }
    for (var n = 201; n <= 225; n++) {
      await store.add('example', 'Example', '', 'senkuro',
        Chapter(id: '$n', name: 'Глава $n'), systemPending: true, sourceId: '1');
    }
    expect((await store.pendingSystemNotifications(limit: 200)).length, 10);
    final library = CountingLibrary();
    expect(await ChapterNotificationService.instance.postNewChapters([],
      libraryStore: library, preferences: InAppOnlyPreferences(),
      permissionCheck: () async => true, sendNotification: (_) async {}), 10);
    expect(library.loads, 1);
  });
  test('opted-in scanner commits OS intent before interruption and permission denial preserves it', () async {
    final source = FakeSource('senkuro')..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {source.key: source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    await ChapterChecker(repository: repo, library: library,
      systemNotificationsEnabled: true,
      afterInboxCommit: () async => throw StateError('process ended')).check();
    expect((await ChapterInboxStore().pendingSystemNotifications()).length, 1);
    expect(await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => false), 0);
    expect((await ChapterInboxStore().pendingSystemNotifications()).length, 1);
    expect(await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async {}), 1);
    expect(await ChapterInboxStore().pendingSystemNotifications(), isEmpty);
  });
  test('queued lease handoff stops on UID change and preserves the other guest records', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    final book = library.items.single.toUnified();
    await library.switchProfile('a');
    await library.setStatus(book, 'reading');
    final store = ChapterInboxStore(profileId: 'a');
    for (var n = 1; n <= 2; n++) {
      await store.add('example', 'Example', '', 'senkuro',
        Chapter(id: '$n', name: 'Глава $n'), systemPending: true, sourceId: '1');
    }
    expect(await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async { await library.switchProfile('b'); }), 1);
    expect((await store.pendingSystemNotifications()).length, 1);
    expect(await ChapterInboxStore(profileId: 'b').load(), isEmpty);
    expect(await ChapterInboxStore(profileId: '').load(), isEmpty);
  });

  for (final queuedV3 in [false, true]) {
    test('v3 shape upgrade preserves lease state and explicit intent: queued=$queuedV3', () async {
      final path = ChapterInboxStore.databasePathOverride!;
      await databaseFactory.deleteDatabase(path);
      final old = await openDatabase(path, version: 3, onCreate: (db, _) async {
        final extra = queuedV3 ? 'systemQueuedAt INTEGER DEFAULT 0' :
          'systemLease INTEGER DEFAULT 0, systemToken INTEGER DEFAULT 0';
        await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, identity TEXT NOT NULL, '
          'payload TEXT NOT NULL, systemClaimed INTEGER DEFAULT 0, $extra, PRIMARY KEY(profile,identity))');
        await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
        await db.insert('migration', {'id': 'legacy-v1'});
        await db.execute('CREATE TABLE scan_state (profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
        const entry = InboxEntry(key: 'example|senkuro|v0:c2', bookKey: 'example',
          title: 'Example', coverUrl: '', source: 'senkuro', chapterId: '2',
          chapterName: 'Глава 2', createdAt: 1);
        await db.insert('inbox', {'profile': '', 'identity': 'example|v0:c2',
          'payload': jsonEncode(entry.toJson()), 'systemClaimed': 0,
          if (queuedV3) 'systemQueuedAt': 1,
          if (!queuedV3) 'systemToken': 5});
      });
      await old.close();
      final store = ChapterInboxStore(profileId: '');
      expect((await store.load()).length, 1);
      expect((await store.pendingSystemNotifications()).length, queuedV3 ? 1 : 0);
      final upgraded = await openDatabase(path);
      expect(await upgraded.getVersion(), 4);
      if (!queuedV3) expect((await upgraded.query('inbox')).single['systemToken'], 5);
    });
  }
  test('read change during a batch stops further handoff without changing page progress', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    final book = library.items.single.toUnified();
    await library.savePosition(book, const Chapter(id: '1', name: 'Глава 1'),
      'senkuro', pageIndex: 7, pageCount: 20);
    final store = ChapterInboxStore();
    for (var n = 2; n <= 3; n++) {
      await store.add('example', 'Example', '', 'senkuro',
        Chapter(id: '$n', name: 'Глава $n'), systemPending: true, sourceId: '1');
    }
    expect(await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async {
        await library.markRead(book, const Chapter(id: '3', name: 'Глава 3'), 'senkuro');
      }), 1);
    await library.load();
    expect(library.items.single.lastPageIndex, 7);
    expect((await store.load()).firstWhere((e) => e.chapterId == '3').hidden, isTrue);
  });

}

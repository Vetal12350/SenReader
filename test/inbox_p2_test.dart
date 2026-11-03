import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/chapter_inbox_panel.dart';
import 'chapter_delivery_regression_test.dart' show InAppOnlyPreferences;
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

const chapter = Chapter(id: 'c2', name: 'Глава 2');
class PausedInbox extends ChapterInboxStore {
  List<InboxEntry> rows = [const InboxEntry(key: 'example|senkuro|v0:c2',
    bookKey: 'example', title: 'Example', coverUrl: '', source: 'senkuro',
    chapterId: 'c2', chapterName: 'Глава 2', createdAt: 1)];
  Completer<void>? pause;
  @override Future<List<InboxEntry>> load() async {
    final snapshot = [...rows];
    await pause?.future;
    return snapshot;
  }
  @override Future<void> hideEntry(String key) async {
    rows = [for (final e in rows) e.key == key ? e.hide(2) : e];
  }
  @override Future<void> setEntriesHidden(Iterable<String> identities,
      {required bool hidden}) async {
    final keys = identities.toSet();
    rows = [for (final e in rows)
      keys.contains(e.key) ? e.hide(hidden ? 2 : 0) : e];
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('poll snapshot cannot resurrect an entry hidden while load is pending', (tester) async {
    final inbox = PausedInbox();
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterInboxPanel(
      library: library, repository: CatalogRepository(sources: {}),
      alerts: ChapterAlertController(), inboxStore: inbox))));
    await tester.pumpAndSettle();
    expect(find.text('Новые (1)'), findsOneWidget);
    final pending = Completer<void>();
    inbox.pause = pending;
    await tester.pump(const Duration(seconds: 8));
    await tester.tap(find.byTooltip('Скрыть обновление'));
    await tester.pump();
    inbox.pause = null;
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Новые (0)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('multiple chapter updates display as one card without source', (tester) async {
    final inbox = PausedInbox();
    inbox.rows = [
      const InboxEntry(key: 'example|readmanga|v0:c178',
        bookKey: 'example', title: 'Незначительный персонаж',
        coverUrl: '', source: 'readmanga', chapterId: '178',
        chapterName: 'Глава 178', createdAt: 200),
      const InboxEntry(key: 'example|readmanga|v0:c177',
        bookKey: 'example', title: 'Незначительный персонаж',
        coverUrl: '', source: 'readmanga', chapterId: '177',
        chapterName: 'Глава 177', createdAt: 100),
    ];
    final library = LibraryStore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterInboxPanel(
      library: library, repository: CatalogRepository(sources: {}),
      alerts: ChapterAlertController(), inboxStore: inbox))));
    await tester.pumpAndSettle();
    expect(find.text('Новые (1)'), findsOneWidget);
    expect(find.text('Главы 177–178'), findsOneWidget);
    expect(find.text('ReadManga'), findsNothing);
    expect(find.byTooltip('Скрыть обновление'), findsOneWidget);

    // Group selection must allow reading chapter 177 first, not silently 178.
    await tester.tap(find.text('Главы 177–178'));
    await tester.pumpAndSettle();
    expect(find.text('Выбери главу'), findsOneWidget);
    expect(find.text('Глава 177'), findsOneWidget);
    expect(find.text('Глава 178'), findsOneWidget);
    await tester.tap(find.text('Глава 177'));
    await tester.pumpAndSettle();
    expect(find.text('Выбери главу'), findsNothing);

    await tester.tap(find.byTooltip('Скрыть обновление'));
    await tester.pumpAndSettle();
    expect(inbox.rows.where((e) => e.hidden).length, 2);
    expect(find.text('Новые (0)'), findsOneWidget);
    expect(find.text('Скрытые (1)'), findsOneWidget);

    await tester.tap(find.text('Скрытые (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Главы 177–178'), findsOneWidget);
    await tester.tap(find.byTooltip('Вернуть в новые'));
    await tester.pumpAndSettle();
    expect(inbox.rows.where((e) => !e.hidden).length, 2);
    expect(find.text('Новые (1)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('bulk archive and restore only change selected chapters in one profile', () async {
    await makeLibrary([FakeSource('senkuro')]);
    final a = ChapterInboxStore(profileId: 'uid-a');
    final b = ChapterInboxStore(profileId: 'uid-b');
    for (final store in [a, b]) {
      for (final number in ['177', '178']) {
        await store.add('story', 'Story', '', 'senkuro',
          Chapter(id: number, name: 'Глава ' + number));
      }
    }
    await a.add('other', 'Other', '', 'senkuro',
      const Chapter(id: '8', name: 'Глава 8'));
    final target = (await a.load()).where((e) => e.bookKey == 'story')
      .map((e) => e.key).toList();
    await a.setEntriesHidden(target, hidden: true);
    expect((await a.load()).where((e) => e.hidden).length, 2);
    expect((await a.load()).firstWhere((e) => e.bookKey == 'other').hidden, isFalse);
    expect((await b.load()).every((e) => !e.hidden), isTrue);
    await a.setEntriesHidden(target, hidden: false);
    expect((await a.load()).every((e) => !e.hidden), isTrue);
  });

  test('pending OS alerts survive an empty discovery report after restart', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    await ChapterInboxStore(profileId: library.profileId)
      .add('example', 'Example', '', 'senkuro', chapter, systemPending: true, sourceId: '1');
    var sends = 0;
    final count = await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async { sends++; });
    expect(count, 1);
    expect(sends, 1);
    expect(await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async { sends++; }), 0);
    expect(sends, 1);
  });
  test('failed platform show must remain retryable without losing the inbox', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    final release = ChapterDiscovery(book: library.items.single.toUnified(),
      sourceKey: 'senkuro', chapter: chapter, canonicalKey: 'v0:c2',
      profileId: library.profileId);
    await ChapterNotificationService.instance.postNewChapters([release],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async => throw StateError('Android process unavailable'));
    expect((await ChapterInboxStore().load()).length, 1);
    expect(await ChapterNotificationService.instance.postNewChapters([release],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (_) async {}), 1);
  });
  test('SQLite late snapshots and replay do not overwrite hidden state across profiles', () async {
    for (final profile in ['', 'a', 'b']) {
      final store = ChapterInboxStore(profileId: profile);
      await store.add('example', 'Example', '', 'senkuro', chapter, systemPending: true, sourceId: '1');
    }
    final a = ChapterInboxStore(profileId: 'a');
    final stale = await a.load();
    await Future.wait([
      a.hideEntry(stale.single.key),
      ChapterInboxStore(profileId: 'a').add('example', 'Example', '', 'readmanga', chapter),
    ]);
    expect(stale.single.hidden, isFalse);
    expect((await a.load()).single.hidden, isTrue);
    for (final profile in ['', 'b']) {
      expect((await ChapterInboxStore(profileId: profile).load()).single.hidden, isFalse);
    }
  });
  test('abandoned OS lease expires; old acknowledgement cannot consume a new lease', () async {
    final store = ChapterInboxStore(profileId: 'a');
    await store.add('example', 'Example', '', 'senkuro', chapter, systemPending: true, sourceId: '1');
    final entry = (await store.load()).single;
    final first = (await store.beginSystemDelivery(entry, now: 1000))!;
    final db = await openDatabase(ChapterInboxStore.databasePathOverride!);
    await db.close(); // simulate connection/process restart with the same database
    final restarted = ChapterInboxStore(profileId: 'a');
    expect(await restarted.beginSystemDelivery(entry, now: 2000), isNull);
    final second = (await restarted.beginSystemDelivery(entry, now: 62000))!;
    await restarted.finishSystemDelivery(entry, first, delivered: true);
    expect(await restarted.beginSystemDelivery(entry, now: 63000), isNull);
    await restarted.finishSystemDelivery(entry, second, delivered: true);
    expect(await restarted.beginSystemDelivery(entry, now: 200000), isNull);
  });
  test('active Android ID is acknowledged after interrupted delivery without showing again', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    final store = ChapterInboxStore();
    await store.add('example', 'Example', '', 'senkuro', chapter, systemPending: true, sourceId: '1');
    final entry = (await store.load()).single;
    await store.beginSystemDelivery(entry, now: 0); // crashed before DB ack
    final release = ChapterDiscovery(book: library.items.single.toUnified(),
      sourceKey: 'senkuro', chapter: chapter, canonicalKey: 'v0:c2', profileId: '');
    var calls = 0;
    await ChapterNotificationService.instance.postNewChapters([],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      activeNotificationIds: () async => {ChapterNotificationService.notificationId(release)},
      sendNotification: (_) async { calls++; });
    expect(calls, 0);
    expect(await store.beginSystemDelivery(entry), isNull);
  });
  test('new OS leases and acknowledgements are isolated for guest and two UIDs', () async {
    final stores = [for (final id in ['', 'a', 'b']) ChapterInboxStore(profileId: id)];
    final tokens = <int>[];
    for (final store in stores) {
      await store.add('example', 'Example', '', 'senkuro', chapter, systemPending: true, sourceId: '1');
      tokens.add((await store.beginSystemDelivery((await store.load()).single, now: 1000))!);
    }
    await stores[1].finishSystemDelivery((await stores[1].load()).single,
      tokens[1], delivered: true);
    expect(await stores[1].beginSystemDelivery((await stores[1].load()).single, now: 62000), isNull);
    for (final index in [0, 2]) {
      expect(await stores[index].beginSystemDelivery((await stores[index].load()).single,
        now: 62000), isNotNull);
    }
  });
  test('SQLite v2 upgrade preserves hidden, delivered and pending rows without changing library', () async {
    final original = ChapterInboxStore.databasePathOverride!;
    ChapterInboxStore.databasePathOverride = '$original.legacy';
    final db = await openDatabase(ChapterInboxStore.databasePathOverride!, version: 2,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, identity TEXT NOT NULL, '
          'payload TEXT NOT NULL, systemClaimed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(profile,identity))');
        await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
        await db.execute('CREATE TABLE scan_state (profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
        await db.insert('scan_state', {'profile': 'a', 'book': 'example',
          'source': 'senkuro', 'sourceId': '1', 'payload': '{"seen":["v0:c1"]}'});
        await db.insert('migration', {'id': 'legacy-v1'});
      });
    final sample = PausedInbox().rows.single;
    await db.insert('inbox', {'profile': 'a', 'identity': 'example|v0:c2',
      'payload': jsonEncode(sample.hide(5).toJson()), 'systemClaimed': 1});
    await db.insert('inbox', {'profile': 'b', 'identity': 'example|v0:c2',
      'payload': jsonEncode(sample.toJson()), 'systemClaimed': 0});
    await db.close();
    final store = ChapterInboxStore(profileId: 'a');
    expect((await store.load()).single.hidden, isTrue);
    expect((await store.loadScanState()).single['payload'], '{"seen":["v0:c1"]}');
    expect(await store.beginSystemDelivery(sample), isNull);
    expect(await ChapterInboxStore(profileId: 'b').beginSystemDelivery(sample), isNull);
    final upgraded = await openDatabase(ChapterInboxStore.databasePathOverride!);
    expect(await upgraded.getVersion(), 4);
    await upgraded.close();
    await databaseFactory.deleteDatabase(ChapterInboxStore.databasePathOverride!);
    ChapterInboxStore.databasePathOverride = original;
  });

}

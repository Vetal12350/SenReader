import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/chapter_inbox_panel.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;
import 'chapter_delivery_regression_test.dart' show InAppOnlyPreferences;

Future<ChapterInboxStore> seed([String title = 'Example']) async {
  final store = ChapterInboxStore(profileId: '');
  for (var n = 1; n <= 3; n++) {
    await store.add('example', title, '', 'senkuro',
      Chapter(id: '$n', name: 'Глава $n'), sourceId: '1', systemPending: true);
  }
  return store;
}

void main() {
  test('three chapter cards and Android notifications survive replay without duplicates', () async {
    await makeLibrary([FakeSource('senkuro')]);
    final store = await seed();
    final sent = <ChapterDiscovery>[];
    Future<int> send() => ChapterNotificationService.instance.postNewChapters(const [],
      preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
      sendNotification: (release) async { sent.add(release); });
    expect((await store.load()).length, 3);
    expect((await Future.wait([send(), send()])).reduce((a,b) => a+b), 3);
    expect(sent.map(ChapterNotificationService.notificationId).toSet().length, 3);
    expect(sent.map((s) => s.chapterCount), everyElement(1));
    await seed();
    expect(await send(), 0);
    final db = await openDatabase(ChapterInboxStore.databasePathOverride!);
    await db.close();
    expect(await send(), 0);
    expect((await ChapterInboxStore(profileId: '').load()).length, 3);
  });

  test('hide, delete tombstone and opening affect only the selected chapter after reopen', () async {
    final store = await seed();
    final rows = await store.load();
    await store.hideEntry(rows[0].key);
    await store.deleteEntry(rows[1].key);
    await store.markOpened(rows[2].key);
    await seed();
    final db = await openDatabase(ChapterInboxStore.databasePathOverride!);
    await db.close();
    final restored = await ChapterInboxStore(profileId: '').load();
    expect(restored.where((e) => e.hidden).map((e) => e.key), [rows[0].key]);
    expect(restored.where((e) => e.deleted).map((e) => e.key), [rows[1].key]);
    expect(restored.where((e) => e.read).map((e) => e.key), [rows[2].key]);
    expect(await store.pendingSystemNotifications(), isEmpty);
    await store.restoreEntry(rows[0].key);
    expect((await store.load()).where((e) => !e.hidden && !e.read && !e.deleted).length, 1);
  });

  test('stable source/title/chapter ID suppresses renamed number after reopen', () async {
    final store = await seed();
    await store.add('renamed', 'Renamed', '', 'senkuro',
      const Chapter(id: '1', name: 'Глава 1.1'), sourceId: '1', systemPending: true);
    expect((await store.load()).length, 3);
  });

  test('369 v4 migration retains chapter IDs, hidden and delivered states', () async {
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final db = await openDatabase(path, version: 4, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT, identity TEXT, payload TEXT, '
        'systemClaimed INTEGER DEFAULT 0, systemLease INTEGER DEFAULT 0, '
        'systemToken INTEGER DEFAULT 0, systemQueuedAt INTEGER DEFAULT 0, PRIMARY KEY(profile, identity))');
      await db.execute('CREATE TABLE migration(id TEXT PRIMARY KEY)');
      await db.insert('migration', {'id': 'legacy-v1'});
      await db.execute('CREATE TABLE scan_state(profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
      for (var n = 1; n <= 3; n++) {
        final entry = InboxEntry(key: 'example|senkuro|v0:c$n', bookKey: 'example',
          title: 'Example', coverUrl: '', source: 'senkuro', sourceId: '1',
          chapterId: '$n', chapterName: 'Глава $n', createdAt: n, hiddenAt: n == 2 ? 5 : 0);
        await db.insert('inbox', {'profile': '', 'identity': 'example|v0:c$n',
          'payload': jsonEncode(entry.toJson()..remove('readAt')..remove('deletedAt')),
          'systemClaimed': 1});
      }
    });
    await db.close();
    final store = ChapterInboxStore(profileId: '');
    expect((await store.load()).map((e) => e.chapterId).toSet(), {'1','2','3'});
    expect((await store.load()).where((e) => e.hidden).single.chapterId, '2');
    await seed();
    expect((await store.load()).length, 3);
    expect(await store.pendingSystemNotifications(), isEmpty);
  });

  test('initial baseline, reordered known chapters and deleted replay stay silent', () async {
    final source = FakeSource('senkuro')..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(repository: CatalogRepository(sources: {source.key: source}), library: library);
    expect((await checker.check()).discoveries, isEmpty);
    source.chapters.addAll([const Chapter(id: '2', name: 'Глава 2'),
      const Chapter(id: '3', name: 'Глава 3'), const Chapter(id: '4', name: 'Глава 4')]);
    expect((await checker.check()).discoveries.length, 3);
    final store = ChapterInboxStore(profileId: '');
    await store.deleteEntry((await store.load()).first.key);
    source.chapters = source.chapters.reversed.toList();
    expect((await checker.check()).discoveries, isEmpty);
    expect((await store.load()).where((e) => !e.deleted).length, 2);
  });

  testWidgets('three independent cards fit narrow screen and dates share button row', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late ChapterInboxStore store;
    await tester.runAsync(() async { store = await seed('Очень длинное название произведения, которое занимает несколько строк на маленьком экране'); });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterInboxPanel(
      library: LibraryStore(), repository: CatalogRepository(sources: {}),
      alerts: ChapterAlertController(), inboxStore: store))));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 80)); });
    await tester.pumpAndSettle();
    expect(find.text('Новые'), findsOneWidget);
    expect(find.text('Скрытые'), findsOneWidget);
    expect(find.text('Вышла новая глава'), findsNWidgets(3));
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(3));
    for (var n = 1; n <= 3; n++) {
      final button = find.text('К главе $n');
      expect(button, findsOneWidget);
      final row = find.ancestor(of: button, matching: find.byType(Row)).first;
      final date = find.descendant(of: row, matching: find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\d{2}\.\d{2}$').hasMatch(w.data ?? '')));
      expect(date, findsOneWidget);
      expect((tester.getCenter(button).dy - tester.getCenter(date).dy).abs(), lessThan(3));
      expect(tester.getCenter(button).dx, lessThan(tester.getCenter(date).dx));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

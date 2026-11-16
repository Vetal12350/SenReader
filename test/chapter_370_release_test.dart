import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/reading_suggestions.dart';

void main() {
  test('Android launch is consumed once and worker initialization retains tap routing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const payload = '{"book":"example","source":"senkuro","titleId":"1",'
      '"chapter":"two","canonical":"v0:c2","profile":""}';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {'notificationLaunchedApp': true, 'notificationResponse': {
          'notificationId': 1, 'notificationResponseType': 1,
          'actionId': 'read_chapter', 'payload': payload}};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ChapterNotificationService.instance;
    await service.initialize();
    expect(ChapterNotificationService.decodePayload(service.openedPayload.value)!['action'], 'chapter');
    service.openedPayload.value = null;
    await service.initialize();
    expect(service.openedPayload.value, isNull, reason: 'A consumed cold launch must not reopen');
    await service.initialize(captureTaps: false);
    await messenger.handlePlatformMessage(channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('didReceiveNotificationResponse', {
        'notificationId': 2, 'notificationResponseType': 0, 'payload': payload})), (_) {});
    expect(ChapterNotificationService.decodePayload(service.openedPayload.value)!['action'], 'title');
    service.openedPayload.value = null;
  });

  test('369 migration preserves 70 synthetic bookmarks, all inbox states and preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    final books = [for (var n = 0; n < 70; n++) SavedBook(title: 'Book $n',
      entries: {'senkuro': MangaEntry(source: 'senkuro', id: '$n', title: 'Book $n')},
      status: 'reading', lastSource: 'senkuro', lastChapter: 'Глава 2', lastChapterId: 'two',
      lastPageIndex: n % 8, lastPageCount: 10, lastUpdatedAt: 1000 + n,
      syncEditedAt: 100000 + n, readChapterKeys: {'senkuro|v0:c1'}).toJson()..remove('lastReading')];
    final raw = jsonEncode(books);
    await prefs.setString(LibraryStore.storageKey, raw);
    await prefs.setString('synthetic.auth', 'fixture');
    await prefs.setString('synthetic.theme', 'dark');
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final old = await openDatabase(path, version: 4, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox(profile TEXT, identity TEXT, payload TEXT, '
        'systemClaimed INTEGER DEFAULT 0, systemLease INTEGER DEFAULT 0, systemToken INTEGER DEFAULT 0, '
        'systemQueuedAt INTEGER DEFAULT 0, PRIMARY KEY(profile,identity))');
      await db.execute('CREATE TABLE migration(id TEXT PRIMARY KEY)');
      await db.insert('migration', {'id': 'legacy-v1'});
      await db.execute('CREATE TABLE scan_state(profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
      await db.insert('scan_state', {'profile': '', 'book': 'book 0', 'source': 'senkuro', 'sourceId': '0',
        'payload': '{"seen":["v0:c1"],"dates":{},"lastCompleteAt":123}'});
      for (var n = 0; n < 4; n++) {
        final entry = InboxEntry(key: '$n', bookKey: 'book 0', title: 'Book 0', coverUrl: '',
          source: 'senkuro', sourceId: '0', chapterId: '$n', chapterName: 'Глава $n', createdAt: n + 1,
          hiddenAt: n == 1 ? 10 : 0, deletedAt: n == 2 ? 11 : 0, readAt: n == 3 ? 12 : 0);
        await db.insert('inbox', {'profile': '', 'identity': 'book 0|v0:c$n',
          'payload': jsonEncode(entry.toJson()), 'systemClaimed': 1});
      }
    });
    await old.close();
    final library = LibraryStore(); await library.load();
    expect(library.items.length, 70);
    expect(prefs.getString(LibraryStore.storageKey), raw);
    expect(recentReadingBooks(library.items).first.title, 'Book 69');
    final store = ChapterInboxStore(profileId: '');
    final rows = await store.load();
    expect(rows.length, 4);
    expect(rows.where((e) => e.hidden).single.chapterId, '1');
    expect(rows.where((e) => e.deleted).single.chapterId, '2');
    expect(rows.where((e) => e.read).single.chapterId, '3');
    expect(await store.pendingSystemNotifications(), isEmpty);
    expect((await store.loadScanState()).single['payload'], contains('123'));
    await store.add('book 0', 'Book 0', '', 'senkuro', const Chapter(id: '2', name: 'Глава 2'), sourceId: '0');
    expect((await store.load()).length, 4);
    await library.setFavorite(library.items.first.toUnified(), true);
    final restarted = LibraryStore(); await restarted.load();
    expect(restarted.items.length, 70);
    expect(recentReadingBooks(restarted.items).map((e) => e.lastUpdatedAt),
      orderedEquals(List.generate(70, (i) => 1069 - i)));
    for (final item in restarted.items) {
      expect(item.lastChapterId, 'two');
      expect(item.readChapterKeys, contains('senkuro|v0:c1'));
      expect(item.syncEditedAt, greaterThan(0));
    }
    expect(prefs.getString('synthetic.auth'), 'fixture');
    expect(prefs.getString('synthetic.theme'), 'dark');
  });
}

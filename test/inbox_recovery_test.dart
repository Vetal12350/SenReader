import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'chapter_checker_test.dart' show makeLibrary;
import 'chapter_delivery_regression_test.dart' show PausingSource, InAppOnlyPreferences;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(
            'dexterous.com/flutter/local_notifications'), (_) async => null);
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final readFirst in [true, false]) {
    test('read and scan reconcile in either order: readFirst=$readFirst', () async {
      final source = PausingSource()
        ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
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

  test('restart before OS handoff recovers once without a new discovery', () async {
    final source = PausingSource()
      ..chapters = [const Chapter(id: '1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(repository: CatalogRepository(
        sources: {source.key: source}), library: library,
        systemNotificationsEnabled: true);
    await checker.check();
    source.chapters = [const Chapter(id: '2', name: 'Глава 2')];
    expect((await checker.check()).discoveries.length, 1);
    // Process ends here, with no OS handoff/claim. A new scan sees no discovery.
    expect((await checker.check()).discoveries, isEmpty);
    final service = ChapterNotificationService.instance;
    expect(await service.postNewChapters([], preferences: InAppOnlyPreferences(),
        permissionCheck: () async => true, sender: (_) async {}), 1);
    expect(await service.postNewChapters([], preferences: InAppOnlyPreferences(),
        permissionCheck: () async => true, sender: (_) async {}), 0);
  });

  test('pending alerts isolate guest/two UIDs, skip read/archive and keep pages', () async {
    final source = PausingSource();
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    for (final profile in ['', 'uid-a', 'uid-b']) {
      await library.switchProfile(profile);
      await library.setStatus(book, 'reading');
      await library.savePosition(book, const Chapter(id: '1', name: 'Глава 1'),
          source.key, pageIndex: 7, pageCount: 20);
      final inbox = ChapterInboxStore(profileId: profile);
      for (var n = 2; n <= 4; n++) {
        await inbox.add('example', 'Example', '', source.key,
            Chapter(id: '$n', name: 'Глава $n'), systemPending: true, sourceId: '1');
      }
      await inbox.hideEntry((await inbox.load()).firstWhere((e) => e.chapterId == '3').key);
      await library.markRead(book, const Chapter(id: '2', name: 'Глава 2'), source.key);
    }
    for (final profile in ['', 'uid-a', 'uid-b']) {
      await library.switchProfile(profile);
      expect(await ChapterNotificationService.instance.postNewChapters([],
          preferences: InAppOnlyPreferences(), permissionCheck: () async => false), 0);
      expect(await ChapterNotificationService.instance.postNewChapters([],
          preferences: InAppOnlyPreferences(), permissionCheck: () async => true, sender: (_) async {}), 1);
      expect(await ChapterNotificationService.instance.postNewChapters([],
          preferences: InAppOnlyPreferences(), permissionCheck: () async => true, sender: (_) async {}), 0);
      await library.load();
      expect(library.items.single.lastPageIndex, 7);
      expect((await ChapterInboxStore(profileId: profile).load()).length, 3);
    }
  });

  test('concurrent workers claim once; crash after claim cannot duplicate', () async {
    final inbox = ChapterInboxStore(profileId: 'uid-a');
    const chapter = Chapter(id: '2', name: 'Глава 2');
    await inbox.add('example', 'Example', '', 'senkuro', chapter, systemPending: true);
    final claims = await Future.wait([for (var i = 0; i < 20; i++)
      ChapterInboxStore(profileId: 'uid-a').claimSystemNotification('example', chapter, 'senkuro')]);
    expect(claims.where((v) => v).length, 1);
    expect(await ChapterInboxStore(profileId: 'uid-a').claimSystemNotification(
        'example', chapter, 'senkuro'), isFalse);
    expect((await inbox.load()).length, 1);
  });

  test('v2 upgrade preserves hidden/claim/scan state, never queues historical rows', () async {
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final old = await openDatabase(path, version: 2, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, identity TEXT NOT NULL, '
          'payload TEXT NOT NULL, systemClaimed INTEGER NOT NULL DEFAULT 0, '
          'PRIMARY KEY(profile, identity))');
      await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
      await db.insert('migration', {'id': 'legacy-v1'});
      await db.execute('CREATE TABLE scan_state (profile TEXT, book TEXT, source TEXT, '
          'sourceId TEXT, payload TEXT, PRIMARY KEY(profile,book,source,sourceId))');
      await db.insert('scan_state', {'profile': '', 'book': 'example', 'source': 'senkuro',
          'sourceId': '1', 'payload': '{"seen":["v0:c2"],"dates":{}}'});
      await db.insert('inbox', {'profile': '', 'identity': 'example|v0:c2',
          'payload': '{"key":"old","bookKey":"example","hiddenAt":42}', 'systemClaimed': 1});
    });
    await old.close();
    final inbox = ChapterInboxStore(profileId: '');
    expect((await inbox.load()).single.hiddenAt, 42);
    expect((await inbox.loadScanState()).single['sourceId'], '1');
    expect(await inbox.pendingSystemNotifications(), isEmpty);
  });

  test('recovery is bounded and ignores entries created before OS opt-in', () async {
    final source = PausingSource();
    await makeLibrary([source]);
    final inbox = ChapterInboxStore(profileId: '');
    await inbox.add('example', 'Example', '', source.key,
        const Chapter(id: 'old', name: 'Глава 1'));
    for (var n = 2; n <= 13; n++) {
      await inbox.add('example', 'Example', '', source.key,
          Chapter(id: '$n', name: 'Глава $n'), systemPending: true, sourceId: '1');
    }
    Future<int> recover() => ChapterNotificationService.instance.postNewChapters([],
        preferences: InAppOnlyPreferences(), permissionCheck: () async => true, sender: (_) async {});
    expect(await recover(), 10);
    expect(await recover(), 2);
    expect(await recover(), 0);
    expect((await inbox.load()).length, 13);
  });

  test('profile switch during recovery stops the next delivery', () async {
    final source = PausingSource();
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    await library.switchProfile('uid-a');
    await library.setStatus(book, 'reading');
    final inbox = ChapterInboxStore(profileId: 'uid-a');
    for (var n = 2; n <= 3; n++) {
      await inbox.add('example', 'Example', '', source.key,
          Chapter(id: '$n', name: 'Глава $n'), sourceId: '1', systemPending: true);
    }
    expect(await ChapterNotificationService.instance.postNewChapters([],
        preferences: InAppOnlyPreferences(), permissionCheck: () async => true,
        sender: (release) async {
          expect(release.profileId, 'uid-a');
          await library.switchProfile('uid-b');
        }), 1);
    expect(await ChapterInboxStore(profileId: 'uid-b').load(), isEmpty);
    expect((await inbox.pendingSystemNotifications()).length, 1);
  });

  test('hidden entry cannot be claimed or reactivated by replay', () async {
    final inbox = ChapterInboxStore(profileId: '');
    const chapter = Chapter(id: '2', name: 'Глава 2');
    await inbox.add('example', 'Example', '', 'senkuro', chapter, systemPending: true);
    final snapshot = await inbox.pendingSystemNotifications();
    await inbox.hideEntry(snapshot.single.key);
    await Future.wait([for (var i = 0; i < 20; i++)
      inbox.add('example', 'Example', '', 'readmanga', chapter, systemPending: true)]);
    expect(await inbox.claimSystemNotification('example', chapter, 'senkuro'), isFalse);
    expect((await inbox.load()).single.hidden, isTrue);
    await inbox.restoreEntry(snapshot.single.key);
    expect((await inbox.load()).single.hidden, isFalse);
  });
}

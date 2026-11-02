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
}

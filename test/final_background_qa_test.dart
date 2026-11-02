import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/ui/reader_page.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/main.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('scan checkpoints never rewrite the reader library payload', () async {
    final source = FakeSource('senkuro');
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    const chapter = Chapter(id: '1', name: 'Глава 1');
    await library.savePosition(book, chapter, source.key,
        pageIndex: 7, pageCount: 20);
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(LibraryStore.storageKey);
    final worker = LibraryStore();
    await worker.load();
    await worker.recordChapterScan('example', source.key, ['v0:c2'],
        expectedProfile: '');
    await prefs.reload();
    expect(prefs.getString(LibraryStore.storageKey), before,
        reason: 'A background read/modify/write of this blob can overwrite a '
            'foreground page save from another isolate.');
    await library.load();
    expect(library.items.single.lastPageIndex, 7);
    expect(library.items.single.readChapterKeys, isEmpty);
    expect(library.items.single.seenChapterKeys, contains('v0:c2'));
  });

  test('concurrent SQLite checkpoints preserve all keys and a reader page save',
      () async {
    final source = FakeSource('readmanga');
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    await Future.wait([
      for (var i = 0; i < 30; i++)
        ChapterInboxStore(profileId: '').recordScan(
            'example', source.key, '1', ['v0:c$i'], {}),
      library.savePosition(book, const Chapter(id: '1', name: 'Глава 1'),
          source.key, pageIndex: 12, pageCount: 20),
    ]);
    await library.load();
    expect(library.items.single.seenChapterKeys.length, 30);
    expect(library.items.single.lastPageIndex, 12);
    expect(library.items.single.readChapterKeys, isEmpty);
    await library.switchProfile('uid-b');
    await library.setStatus(book, 'reading');
    expect(library.items.single.seenChapterKeys, isEmpty);
    await library.switchProfile(null);
    expect(library.items.single.seenChapterKeys.length, 30);
    expect(library.items.single.lastPageIndex, 12);
  });

  test('SQLite v1 upgrade preserves hidden inbox and notification claims', () async {
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final old = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, '
          'identity TEXT NOT NULL, payload TEXT NOT NULL, '
          'systemClaimed INTEGER NOT NULL DEFAULT 0, '
          'PRIMARY KEY(profile, identity))');
      await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
      await db.insert('migration', {'id': 'legacy-v1'});
      await db.insert('inbox', {
        'profile': '', 'identity': 'example|v0:c2', 'systemClaimed': 1,
        'payload': '{"key":"example|readmanga|v0:c2","bookKey":"example",'
            '"chapterId":"2","chapterName":"Глава 2","hiddenAt":42}',
      });
    });
    await old.close();
    final inbox = ChapterInboxStore(profileId: '');
    expect((await inbox.load()).single.hidden, isTrue);
    expect(await inbox.claimSystemNotification('example',
        const Chapter(id: '2', name: 'Глава 2'), 'readmanga'), isFalse);
    await inbox.recordScan('example', 'readmanga', '1', ['v0:c2'], {});
    expect((await inbox.loadScanState()).length, 1);
    expect((await inbox.load()).single.hiddenAt, 42);
  });

  for (final count in [70, 200]) {
    test('$count books deliver every update across bounded worker restarts',
        () async {
      final source = FakeSource('readmanga')
        ..chapters = [const Chapter(id: '2', name: 'Глава 2')];
      final library = LibraryStore();
      await library.load();
      for (var i = 0; i < count; i++) {
        await library.setStatus(UnifiedManga(title: 'Book $i', entries: {
          source.key: MangaEntry(source: source.key, id: '$i', title: 'Book $i'),
        }), 'reading');
        await ChapterInboxStore(profileId: '').recordScan(
            'book $i', source.key, '$i', ['v0:c1'], {});
      }
      var found = 0;
      for (var offset = 0; offset < count; offset += 20) {
        final worker = LibraryStore();
        await worker.load();
        var done = 0;
        final report = await ChapterChecker(
          repository: CatalogRepository(sources: {source.key: source}),
          library: worker, elapsed: () => Duration(seconds: done),
          afterPair: () async { done++; },
        ).check(smartSchedule: true, budget: const Duration(seconds: 20));
        expect(report.warnings, isEmpty);
        found += report.discoveries.length;
      }
      final inbox = await ChapterInboxStore(profileId: '').load();
      expect(found, count);
      expect(inbox.map((e) => e.bookKey).toSet().length, count);
      expect(source.detailCalls, count);
      expect(source.pageCalls, count);
      await library.load();
      expect(library.items.every((b) => b.readChapterKeys.isEmpty &&
          b.lastChapter.isEmpty && b.preferredSource == source.key), isTrue);
    });
  }

  test('first scan leaves excess recent releases retryable beyond 36 hours', () async {
    final source = FakeSource('senkuro')..chapters = [
      const Chapter(id: '1', name: 'Глава 1'),
      for (var i = 2; i <= 6; i++)
        Chapter(id: '$i', name: 'Глава $i', publishedAt: DateTime.now()
            .subtract(const Duration(hours: 1))),
    ];
    final library = await makeLibrary([source]);
    await library.markRead(library.items.single.toUnified(),
        source.chapters.first, source.key);
    final checker = ChapterChecker(repository: CatalogRepository(
        sources: {source.key: source}), library: library);
    expect((await checker.check()).discoveries.length, 2);
    expect(library.items.single.seenChapterKeys,
        isNot(contains('v0:c2')));
    // A delayed next run must not rely on the 36-hour legacy recovery window.
    source.chapters = [
      source.chapters.first,
      for (var i = 2; i <= 6; i++)
        Chapter(id: '$i', name: 'Глава $i', publishedAt: DateTime.now()
            .subtract(const Duration(days: 3))),
    ];
    expect((await checker.check()).discoveries.length, 3);
    expect((await ChapterInboxStore().load()).length, 5);
  });

  testWidgets('open Home polls new SQLite rows and removes archived suggestions',
      (tester) async {
    final source = FakeSource('readmanga');
    final library = await makeLibrary([source]);
    await library.savePosition(library.items.single.toUnified(),
        const Chapter(id: '1', name: 'Глава 1'), source.key,
        pageIndex: 9, pageCount: 10);
    await tester.pumpWidget(MaterialApp(home: MainShell(
      library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      alerts: ChapterAlertController(
          preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    final inbox = ChapterInboxStore(profileId: '');
    await inbox.add('example', 'Example', '', source.key,
        const Chapter(id: '2', name: 'Глава 2'));
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.textContaining('Новая:'), findsOneWidget);
    await inbox.hideEntry((await inbox.load()).single.key);
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.textContaining('Новая:'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old account notification cannot open a new account chapter',
      (tester) async {
    final source = FakeSource('readmanga')
      ..chapters = [const Chapter(id: '2', name: 'Глава 2')];
    final library = LibraryStore();
    await library.switchProfile('uid-b');
    final book = UnifiedManga(title: 'Example', entries: {
      source.key: const MangaEntry(source: 'readmanga', id: '1', title: 'Example'),
    });
    await library.setStatus(book, 'reading');
    await tester.pumpWidget(MaterialApp(home: MainShell(
      library: library,
      repository: CatalogRepository(sources: {source.key: source}),
      alerts: ChapterAlertController(
          preferences: MemoryAlertPreferences()..shown = true),
    )));
    await tester.pumpAndSettle();
    ChapterNotificationService.instance.openedPayload.value =
        ChapterNotificationService.encodePayload(ChapterDiscovery(
          book: book, sourceKey: source.key, chapter: source.chapters.single,
          canonicalKey: 'v0:c2', profileId: 'uid-a'));
    await tester.pumpAndSettle();
    expect(source.detailCalls, 0);
    expect(library.items.single.lastChapter, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('stale reader mutations cannot touch another profile', () async {
    final source = FakeSource('readmanga');
    final book = UnifiedManga(title: 'Example', entries: {
      source.key: const MangaEntry(
          source: 'readmanga', id: '1', title: 'Example'),
    });
    const old = Chapter(id: '2', name: 'Глава 2');
    const newChapter = Chapter(id: '99', name: 'Глава 99');
    final library = LibraryStore();
    await library.switchProfile('uid-a');
    await library.setStatus(book, 'reading');
    await library.savePosition(book, old, source.key,
        pageIndex: 1, pageCount: 20);
    await library.switchProfile('uid-b');
    await library.setStatus(book, 'reading');
    await library.savePosition(book, newChapter, source.key,
        pageIndex: 7, pageCount: 20);

    await library.savePosition(book, old, source.key,
        pageIndex: 3, pageCount: 20, expectedProfile: 'uid-a');
    await library.markRead(book, old, source.key,
        expectedProfile: 'uid-a');
    await library.recordLatestChapter(book, source.key, [old],
        expectedProfile: 'uid-a');
    await library.unmarkRead(book, newChapter, source.key,
        expectedProfile: 'uid-a');

    await library.load();
    expect(library.profileId, 'uid-b');
    expect(library.items.single.lastChapterId, '99');
    expect(library.items.single.lastPageIndex, 7);
    expect(library.items.single.readChapterKeys, isEmpty);
    expect(library.items.single.latestKnownChapterId, isEmpty);
    await library.switchProfile('uid-a');
    expect(library.items.single.lastChapterId, '2');
    expect(library.items.single.lastPageIndex, 1);
  });

  testWidgets('delayed ReaderPage load cannot overwrite newly active account',
      (tester) async {
    final source = _BlockedReaderSource();
    const chapterA = Chapter(id: '2', name: 'Глава 2');
    const chapterB = Chapter(id: '99', name: 'Глава 99');
    final book = UnifiedManga(title: 'Example', entries: {
      'readmanga': const MangaEntry(
          source: 'readmanga', id: '1', title: 'Example'),
    });
    final library = LibraryStore();
    await library.switchProfile('uid-a');
    await library.setStatus(book, 'reading');
    await tester.pumpWidget(MaterialApp(home: ReaderPage(
      book: book, chapter: chapterA, sourceKey: source.key,
      repository: CatalogRepository(sources: {source.key: source}),
      library: library,
      chapters: const [chapterA],
    )));
    await tester.pump();

    await library.switchProfile('uid-b');
    await library.setStatus(book, 'reading');
    await library.savePosition(book, chapterB, source.key,
        pageIndex: 7, pageCount: 20);

    // The HTTP result belongs to A, but is delivered while B is active.
    source.completePages();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await library.load();
    expect(library.profileId, 'uid-b');
    expect(library.items.single.lastChapterId, '99');
    expect(library.items.single.lastPageIndex, 7);
    expect(library.items.single.readChapterKeys, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _BlockedReaderSource extends FakeSource {
  _BlockedReaderSource() : super('readmanga');
  final Completer<List<PageImage>> _pages = Completer<List<PageImage>>();

  @override
  Future<List<PageImage>> pages(Chapter chapter) => _pages.future;

  void completePages() {
    _pages.complete([const PageImage('https://cdn.example.com/reader-test.jpg')]);
  }
}

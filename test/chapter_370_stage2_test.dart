import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/reading_suggestions.dart';
import 'package:senreader/ui/notification_navigation.dart';
import 'package:senreader/ui/detail_page.dart';
import 'package:senreader/ui/reader_page.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

const first = Chapter(id: 'one', name: 'Глава 1');
const second = Chapter(id: 'two', name: 'Глава 2');
UnifiedManga title(String id) => UnifiedManga(title: id, entries: {
  'senkuro': MangaEntry(source: 'senkuro', id: id, title: id)});

void main() {
  test('actual reading controls order across metadata edits, sync and restart', () async {
    final library = LibraryStore(); await library.load();
    final a = title('A'); final b = title('B');
    await library.savePosition(a, first, 'senkuro', pageIndex: 3, pageCount: 10);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await library.savePosition(b, second, 'senkuro', pageIndex: 7, pageCount: 10);
    await library.markRead(a, first, 'senkuro');
    final before = library.get(a)!.lastReading!.at;
    await library.markViewed(a);
    await library.unmarkRead(a, second, 'senkuro');
    expect(library.get(a)!.lastReading!.at, before);
    final cloud = library.get(a)!.toJson()
      ..['readChapterKeys'] = []
      ..['lastReading'] = ReadingVisit(source: 'senkuro', titleId: 'A',
        chapterId: 'old', chapterName: 'Глава 0', pageIndex: 0, pageCount: 1, at: 1).toJson();
    final remoteRevision = library.get(a)!.syncEditedAt + 100;
    await library.mergeCloudRecords({'a': {'editedAt': remoteRevision, 'book': cloud}});
    expect((await library.exportCloudRecords())['a']!['editedAt'], greaterThan(remoteRevision));
    final reopened = LibraryStore(); await reopened.load();
    final recent = recentReadingBooks(reopened.items);
    expect(recent.map((e) => e.title), ['B', 'A']);
    expect(recent.last.lastChapterId, 'one');
    expect(recent.last.lastPageIndex, 3);
    expect(reopened.isChapterRead(a, first, 'senkuro'), isTrue);
    expect(recent.last.lastUpdatedAt, before);
    final restored = LibraryStore(); await restored.load();
    await restored.mergeCloudRecords(await reopened.exportCloudRecords());
    expect(recentReadingBooks(restored.items).map((e) => e.lastChapterId), ['two', 'one']);
  });

  test('unknown historical dates stay zero and source-title duplicates collapse', () {
    final raw = SavedBook(title: 'A', entries: title('A').entries,
      lastChapter: first.name, lastChapterId: first.id, lastSource: 'senkuro').toJson()
      ..remove('lastReading');
    final legacy = SavedBook.fromJson(raw);
    expect(legacy.lastReading!.at, 0);
    final renamed = SavedBook.fromJson({...raw, 'title': 'Alias'});
    expect(recentReadingBooks([legacy, renamed]).length, 1);
    expect(recentReadingBooks([legacy]).single.lastUpdatedAt, 0);
    expect(recentReadingBooks([SavedBook(title: 'Never read', entries: title('A').entries)]), isEmpty);
  });

  test('restoring cloud visit keeps genuine timestamp and exact chapter', () async {
    final library = LibraryStore(); await library.load();
    final book = SavedBook(title: 'A', entries: title('A').entries,
      lastReading: const ReadingVisit(source: 'senkuro', titleId: 'A', chapterId: 'one',
        chapterName: 'Глава 1', pageIndex: 5, pageCount: 20, at: 12345));
    await library.mergeCloudRecords({'a': {'editedAt': 999999, 'book': book.toJson()}});
    final home = recentReadingBooks(library.items).single;
    expect(home.lastUpdatedAt, 12345);
    expect(home.lastChapterId, 'one');
    expect(home.lastPageIndex, 5);
  });

  test('notification responses select title or exact chapter across serialize/restart', () async {
    final source = FakeSource('senkuro'); final library = await makeLibrary([source]);
    for (final chapter in [first, second]) {
      final payload = ChapterNotificationService.encodePayload(ChapterDiscovery(
        book: library.items.single.toUnified(), sourceKey: 'senkuro', chapter: chapter,
        canonicalKey: chapter.id, profileId: ''));
      final body = ChapterNotificationService.decodePayload(
        ChapterNotificationService.routePayload(payload, null))!;
      final action = ChapterNotificationService.decodePayload(
        ChapterNotificationService.routePayload(payload, ChapterNotificationService.readChapterAction))!;
      final reopened = LibraryStore(); await reopened.load();
      expect(body['action'], 'title'); expect(action['action'], 'chapter');
      expect(action['chapter'], chapter.id);
      expect(notificationBook(reopened, action)!.entries['senkuro']!.id, '1');
      expect(notificationChapter([first, second], action['chapter']!)!.id, chapter.id);
      expect(notificationBook(reopened, {...action, 'titleId': 'different'}), isNull);
      expect(notificationBook(reopened, {...action, 'profile': 'another'}), isNull);
    }
    expect(notificationChapter([second], first.id), isNull);
  });

  for (final selected in [first, second]) {
    test('successful opening ${selected.id} changes only its inbox status', () async {
      final library = await makeLibrary([FakeSource('senkuro')]);
      final book = library.items.single.toUnified(); final store = ChapterInboxStore(profileId: '');
      for (final chapter in [first, second]) {
        await store.add('example', 'Example', '', 'senkuro', chapter, sourceId: '1');
      }
      await library.savePosition(book, selected, 'senkuro', pageIndex: 0, pageCount: 10);
      await library.markRead(book, selected, 'senkuro', availableChapters: [first, second]);
      final rows = await store.load();
      expect(rows.where((e) => e.read).map((e) => e.chapterId), [selected.id]);
      expect(rows.any((e) => e.hidden || e.deleted), false);
      final reopened = LibraryStore(); await reopened.load();
      expect(recentReadingBooks(reopened.items).single.lastChapterId, selected.id);
    });
  }

  for (final action in ['title', 'chapter', 'missing']) {
    testWidgets('notification navigation $action uses correct page without substitution', (tester) async {
      final source = FakeSource('senkuro')..chapters = [first, second];
      late LibraryStore library;
      await tester.runAsync(() async { library = await makeLibrary([source]); });
      late BuildContext pageContext;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        pageContext = context; return const Text('Home');
      }))));
      await tester.runAsync(() async {
        unawaited(openChapterNotification(pageContext, fields: {'profile': '', 'book': 'example',
          'source': 'senkuro', 'titleId': '1', 'chapter': action == 'missing' ? 'missing' : 'one',
          'action': action == 'title' ? 'title' : 'chapter'}, library: library,
          repository: CatalogRepository(sources: {source.key: source})));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
      if (action == 'title') {
        expect(find.byType(DetailPage), findsOneWidget);
        expect(find.byType(ReaderPage), findsNothing);
        expect(library.items.single.lastReading, isNull);
        expect(library.items.single.readChapterKeys, isEmpty);
      } else if (action == 'chapter') {
        expect(find.byType(ReaderPage), findsOneWidget);
        expect(tester.widget<ReaderPage>(find.byType(ReaderPage)).chapter.id, 'one');
      } else {
        expect(find.byType(ReaderPage), findsNothing);
        expect(find.text('Глава больше недоступна'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
    });
  }
}

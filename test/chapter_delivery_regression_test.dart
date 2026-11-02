import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_preferences.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/chapter_notification_service.dart';
import 'package:senreader/data/library_store.dart';
import 'chapter_checker_test.dart' show FakeSource, makeLibrary;

const chapter = Chapter(id: 's2', name: 'Глава 2');
Future<void> add(ChapterInboxStore store, {String source = 'senkuro'}) =>
    store.add('example', 'Example', '', source, chapter);

class InAppOnlyPreferences extends ChapterAlertPreferences {
  @override Future<bool> enabled() async => true;
  @override Future<bool> systemNotificationsEnabled() async => true;
}

class PausingSource extends FakeSource {
  PausingSource() : super('senkuro');
  Completer<void>? paused;
  Completer<void>? resume;
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    paused?.complete();
    await resume?.future;
    return super.pages(chapter);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('guest and two UIDs isolate identical titles, hidden state and OS claims', () async {
    for (final profile in ['', 'uid-a', 'uid-b']) {
      final library = LibraryStore();
      await library.switchProfile(profile);
      await add(ChapterInboxStore());
    }
    final a = ChapterInboxStore(profileId: 'uid-a');
    final entry = (await a.load()).single;
    await a.hideEntry(entry.key);
    expect((await a.load()).single.hidden, isTrue);
    for (final profile in ['', 'uid-b']) {
      final store = ChapterInboxStore(profileId: profile);
      expect((await store.load()).single.hidden, isFalse);
      expect(await store.claimSystemNotification('example', chapter, 'senkuro'), isTrue);
    }
    expect(await a.claimSystemNotification('example', chapter, 'senkuro'), isTrue);
    expect(await a.claimSystemNotification('example', chapter, 'readmanga'), isFalse);
  });

  test('legacy global inbox migrates only to guest and original is retained', () async {
    final entry = InboxEntry(key: 'example|senkuro|v0:c2', bookKey: 'example',
      title: 'Example', coverUrl: '', source: 'senkuro', chapterId: 's2',
      chapterName: 'Глава 2', createdAt: 1, hiddenAt: 2);
    final raw = jsonEncode([entry.toJson()]);
    SharedPreferences.setMockInitialValues({ChapterInboxStore.key: raw});
    expect(await ChapterInboxStore(profileId: 'uid-a').load(), isEmpty);
    expect(await ChapterInboxStore(profileId: 'uid-b').load(), isEmpty);
    expect((await ChapterInboxStore(profileId: '').load()).single.hidden, isTrue);
    expect((await SharedPreferences.getInstance()).getString(ChapterInboxStore.key), raw);
  });

  test('malformed legacy storage cannot block authenticated or guest inbox', () async {
    const raw = '{invalid legacy json';
    SharedPreferences.setMockInitialValues({ChapterInboxStore.key: raw});
    final authenticated = ChapterInboxStore(profileId: 'uid-a');
    await add(authenticated);
    expect((await authenticated.load()).single.chapterId, 's2');
    final guest = ChapterInboxStore(profileId: '');
    await add(guest);
    expect((await guest.load()).single.chapterId, 's2');
    expect((await SharedPreferences.getInstance())
        .getString(ChapterInboxStore.key), raw);
  });

  test('concurrent insert/hide and cross-source replay keep one hidden record', () async {
    final a = ChapterInboxStore(profileId: 'uid-a');
    final b = ChapterInboxStore(profileId: 'uid-a');
    await add(a);
    final key = (await a.load()).single.key;
    await Future.wait([
      for (var i = 0; i < 20; i++) add(b, source: 'readmanga'),
      a.hideEntry(key),
    ]);
    expect((await b.load()).length, 1);
    expect((await b.load()).single.hidden, isTrue);
    await b.restoreEntry(key);
    expect((await a.load()).single.hidden, isFalse);
  });

  test('interruption after inbox commit before seen is recovered without duplication', () async {
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 's1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final repo = CatalogRepository(sources: {'senkuro': source});
    await ChapterChecker(repository: repo, library: library).check();
    source.chapters = [chapter];
    await ChapterChecker(repository: repo, library: library,
      afterInboxCommit: () async => throw StateError('simulated process stop'))
        .check();
    expect((await ChapterInboxStore().load()).single.chapterId, 's2');
    expect(library.items.single.seenChapterKeys, isNot(contains('v0:c2')));
    final restored = LibraryStore();
    await restored.load();
    await ChapterChecker(repository: repo, library: restored).check();
    expect((await ChapterInboxStore().load()).length, 1);
    expect(restored.items.single.seenChapterKeys, contains('v0:c2'));
    expect(restored.items.single.readChapterKeys, isEmpty);
  });

  test('account switch during verification never delivers or marks the other UID', () async {
    final source = PausingSource()
      ..chapters = [const Chapter(id: 's1', name: 'Глава 1')];
    final profile = LibraryStore();
    await profile.switchProfile('uid-a');
    final library = await makeLibrary([source]);
    final book = library.items.single.toUnified();
    final checker = ChapterChecker(repository: CatalogRepository(
      sources: {'senkuro': source}), library: library);
    await checker.check();
    source.chapters = [chapter];
    source.paused = Completer<void>();
    source.resume = Completer<void>();
    final scan = checker.check();
    await source.paused!.future;
    final other = LibraryStore();
    await other.switchProfile('uid-b');
    await other.setStatus(book, 'reading');
    source.resume!.complete();
    expect((await scan).discoveries, isEmpty);
    expect(await ChapterInboxStore(profileId: 'uid-a').load(), isEmpty);
    expect(await ChapterInboxStore(profileId: 'uid-b').load(), isEmpty);
    await other.load();
    expect(other.items.single.seenChapterKeys, isEmpty);
    expect(other.items.single.readChapterKeys, isEmpty);
  });

  test('scanner commits inbox with no notification plugin or POST_NOTIFICATIONS', () async {
    SharedPreferences.setMockInitialValues({
      ChapterAlertPreferences.inAppEnabledKey: true,
      ChapterAlertPreferences.systemEnabledKey: true,
    });
    final source = FakeSource('senkuro')
      ..chapters = [const Chapter(id: 's1', name: 'Глава 1')];
    final library = await makeLibrary([source]);
    final checker = ChapterChecker(repository: CatalogRepository(
      sources: {'senkuro': source}), library: library);
    await checker.check();
    source.chapters = [chapter];
    final report = await checker.check();
    // No permission or MethodChannel handler has been installed.
    await ChapterNotificationService.instance.postNewChapters(report.discoveries,
      preferences: InAppOnlyPreferences(), permissionCheck: () async => false);
    expect((await ChapterInboxStore().load()).single.chapterId, 's2');
    expect((await checker.check()).discoveries, isEmpty);
  });
}

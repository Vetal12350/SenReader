import 'dart:async';
import 'package:flutter/material.dart';
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
  test('pending OS alerts survive an empty discovery report after restart', () async {
    final library = await makeLibrary([FakeSource('senkuro')]);
    await ChapterInboxStore(profileId: library.profileId)
      .add('example', 'Example', '', 'senkuro', chapter);
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
}

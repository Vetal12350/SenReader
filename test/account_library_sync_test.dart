import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/cloud_library_sync.dart';
import 'package:senreader/data/firebase_account_service.dart';
import 'package:senreader/data/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final book = UnifiedManga(title: 'Гостевая серия', entries: {
    'senkuro': const MangaEntry(source: 'senkuro', id: 'guest',
      title: 'Гостевая серия'),
  });
  const chapter = Chapter(id: '42', name: 'Глава 42');

  test('switching accounts never exposes guest or another account library',
      () async {
    final library = LibraryStore();
    await library.load();
    await library.savePosition(book, chapter, 'senkuro',
      pageIndex: 7, pageCount: 10);
    expect(library.items.length, 1);

    await library.switchProfile('userA');
    expect(library.items, isEmpty);
    await library.setStatus(book, 'reading');
    await library.switchProfile('userB');
    expect(library.items, isEmpty);
    await library.switchProfile('userA');
    expect(library.get(book)!.status, 'reading');
    await library.switchProfile(null);
    expect(library.get(book)!.lastPageIndex, 7);
    expect(library.get(book)!.status, 'viewed');
    final reopened = LibraryStore();
    await reopened.load();
    expect(reopened.profileId, '');
    expect(reopened.get(book)!.lastPageIndex, 7);
  });

  test('guest import is explicit and never overwrites account progress',
      () async {
    final library = LibraryStore();
    await library.load();
    await library.savePosition(book, chapter, 'senkuro',
      pageIndex: 7, pageCount: 10);
    await library.switchProfile('userA');
    await library.savePosition(book, chapter, 'senkuro',
      pageIndex: 3, pageCount: 10);
    final result = await library.importGuestLibrary();
    expect(result.added, 0);
    expect(result.skipped, 1);
    expect(library.get(book)!.lastPageIndex, 3);
  });

  test('newer cloud record syncs, older cannot rewind reading position',
      () async {
    final library = LibraryStore();
    await library.load();
    await library.switchProfile('userA');
    await library.savePosition(book, chapter, 'senkuro',
      pageIndex: 6, pageCount: 10);
    final local = await library.exportCloudRecords();
    final key = library.get(book)!.key;
    final revision = local[key]!['editedAt'] as int;
    final older = Map<String, dynamic>.from(local[key]!);
    older['editedAt'] = revision - 1;
    final oldBook = Map<String, dynamic>.from(
      local[key]!['book'] as Map);
    oldBook['lastPageIndex'] = 0;
    older['book'] = oldBook;
    expect(await library.mergeCloudRecords({key: older}), 0);
    expect(library.get(book)!.lastPageIndex, 6);

    final newer = Map<String, dynamic>.from(older)
      ..['editedAt'] = revision + 1000000;
    expect(await library.mergeCloudRecords({key: newer}), 1);
    expect(library.get(book)!.lastPageIndex, 0);
    final records = await library.exportCloudRecords();
    expect(records[key]!['editedAt'], revision + 1000000);
  });

  test('removal generates tombstone and prevents stale restore', () async {
    final library = LibraryStore();
    await library.load();
    await library.switchProfile('userA');
    await library.add(book);
    final key = library.get(book)!.key;
    final before = await library.exportCloudRecords();
    await library.remove(book);
    expect(library.items, isEmpty);
    final after = await library.exportCloudRecords();
    expect(after[key]!['deleted'], true);
    expect(after[key]!['editedAt'], greaterThan(before[key]!['editedAt']));
    expect(await library.mergeCloudRecords({key: before[key]!}), 0);
    expect(library.items, isEmpty);
  });

  test('chapter positions survive cloud round-trip and explicit unread resets them', () async {
    const next = Chapter(id: '43', name: 'Глава 43');
    final original = LibraryStore();
    await original.savePosition(book, chapter, 'senkuro', pageIndex: 7, pageCount: 10);
    await original.savePosition(book, next, 'senkuro', pageIndex: 5, pageCount: 10);
    final cloud = await original.exportCloudRecords();

    final restored = LibraryStore();
    await restored.switchProfile('cloud-receiver');
    expect(await restored.mergeCloudRecords(cloud), 1);
    expect(restored.get(book)!.pageIndexFor(chapter, 'senkuro'), 7);
    expect(restored.get(book)!.pageIndexFor(next, 'senkuro'), 5);
    await restored.unmarkRead(book, chapter, 'senkuro', availableChapters: [chapter, next]);
    await restored.load();
    expect(restored.get(book)!.pageIndexFor(chapter, 'senkuro'), 0);
    expect(restored.get(book)!.pageIndexFor(next, 'senkuro'), 0);
  });

  test('hashing Firestore document ID is stable for Unicode and slashes', () {
    final value = CloudLibrarySync.documentId('Манхва/Глава: 42');
    expect(value.length, 64);
    expect(value, isNot(contains('/')));
    expect(value, CloudLibrarySync.documentId('Манхва/Глава: 42'));
  });

  test('without project configuration account mode remains optional', () async {
    expect(SenReaderFirebaseConfig.configured, isFalse);
    final library = LibraryStore();
    final accounts = FirebaseAccountService(library);
    await accounts.initialize();
    expect(accounts.ready, true);
    expect(accounts.signedIn, false);
    expect(accounts.cloud, isNull);
    accounts.dispose();
  });
}

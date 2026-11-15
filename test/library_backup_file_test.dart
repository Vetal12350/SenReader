import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/settings_page.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

List<Map<String, dynamic>> syntheticBooks() => [for (var n = 0; n < 70; n++)
  SavedBook(title: 'Synthetic book $n', entries: {
    'senkuro': MangaEntry(source: 'senkuro', id: '$n', title: 'Synthetic book $n')},
    status: 'reading', favorite: n.isEven, lastSource: 'senkuro', preferredSource: 'senkuro',
    lastChapter: 'Глава 250', lastChapterId: 'chapter-250',
    lastPageIndex: n % 10, lastPageCount: 20, lastUpdatedAt: 1000 + n,
    syncEditedAt: 5000 + n,
    readChapterKeys: {for (var i = 0; i < 250; i++) 'senkuro|v0:c$i'},
    seenChapterKeys: {for (var i = 0; i < 250; i++) 'v0:c$i'},
    initializedSources: {'senkuro'},
    sourceSeenChapterKeys: {'senkuro': {for (var i = 0; i < 250; i++) 'v0:c$i'}},
    sourceChapterDates: {for (var i = 0; i < 250; i++) 'senkuro|v0:c$i': 1600000000000 + i},
  ).toJson()..remove('lastReading')];

Future<LibraryStore> libraryFixture() async {
  SharedPreferences.setMockInitialValues({LibraryStore.storageKey: jsonEncode(syntheticBooks())});
  final library = LibraryStore(); await library.load(); return library;
}

void main() {
  test('70-book JSON exceeds observed Binder parcel and remains compatible lossless backup', () async {
    final library = await libraryFixture();
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(LibraryStore.storageKey);
    final raw = await library.exportBackup();
    expect(raw.length * 2, greaterThan(1121068));
    expect(library.previewBackup(raw).books, 70);
    final records = (jsonDecode(raw) as Map)['books'] as List;
    for (var n = 0; n < 70; n++) {
      expect(records[n]['syncEditedAt'], 5000 + n);
      expect(records[n]['lastPageIndex'], n % 10);
      expect((records[n]['readChapterKeys'] as List).length, 250);
      expect((records[n]['sourceChapterDates'] as Map).length, 250);
    }
    expect(prefs.getString(LibraryStore.storageKey), before);
    SharedPreferences.setMockInitialValues({});
    final restored = LibraryStore();
    expect((await restored.importBackup(raw)).added, 70);
    for (final book in restored.items) {
      expect(book.lastChapterId, 'chapter-250');
      expect(book.readChapterKeys.length, 250);
      expect(book.sourceChapterDates.length, 250);
    }
  });

  testWidgets('save uses file bytes, verifies read-back SHA256, rejects alteration without imports', (tester) async {
    late LibraryStore library;
    late Directory dir;
    late String original;
    await tester.runAsync(() async {
      library = await libraryFixture();
      original = (await SharedPreferences.getInstance()).getString(LibraryStore.storageKey)!;
      dir = await Directory.systemTemp.createTemp('senreader-backup-file-test-');
    });
    addTearDown(() async => dir.delete(recursive: true));
    final file = File('${dir.path}/70-book-backup.json');
    Uint8List? savedBytes;
    var clipboardCalls = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardCalls++;
      return null;
    });
    messenger.setMockMethodCallHandler(picker, (call) async {
      if (call.method == 'save') {
        savedBytes = (call.arguments as Map)['bytes'] as Uint8List;
        await file.writeAsBytes(savedBytes!, flush: true);
        return file.path;
      }
      if (call.method == 'custom') return [{'name': '70-book-backup.json',
        'path': file.path, 'size': await file.length(), 'identifier': 'fixture'}];
      throw StateError('Unexpected picker method');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(picker, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(MaterialApp(home: SettingsPage(library: library,
      repository: CatalogRepository(sources: {}), alerts: ChapterAlertController(preferences: MemoryAlertPreferences()))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('backup-save')), 400);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup-save')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(savedBytes, isNotNull);
    late String digest;
    await tester.runAsync(() async {
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes, savedBytes);
      expect(library.previewBackup(utf8.decode(bytes)).books, 70);
      digest = sha256.convert(bytes).toString();
    });
    await tester.ensureVisible(find.byKey(const Key('backup-verify')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup-verify')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Файл проверен: 70'), findsOneWidget);
    expect(find.textContaining(digest), findsOneWidget);
    await tester.runAsync(() async {
      expect((await SharedPreferences.getInstance()).getString(LibraryStore.storageKey), original);
      final changed = jsonDecode(utf8.decode(savedBytes!)) as Map;
      (changed['books'] as List).first['lastPageIndex'] = 99;
      await file.writeAsString(jsonEncode(changed), flush: true);
      await tester.tap(find.byKey(const Key('backup-verify')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Файл не прошёл проверку'), findsOneWidget);
    expect(clipboardCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failure in [false, true]) {
    testWidgets('save cancellation/platformError=$failure leaves library intact', (tester) async {
      late LibraryStore library;
      await tester.runAsync(() async { library = await libraryFixture(); });
      const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(picker, (call) async {
        if (failure) throw PlatformException(code: 'fixture_io_error');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
      await tester.pumpWidget(MaterialApp(home: SettingsPage(library: library,
        repository: CatalogRepository(sources: {}), alerts: ChapterAlertController(preferences: MemoryAlertPreferences()))));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('backup-save')), 400);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('backup-save')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Сохранение завершено'), findsNothing);
      if (failure) expect(find.textContaining('Не удалось сохранить файл'), findsOneWidget);
      expect(library.items.length, 70);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';

/// A1: saving the reading position must not decode the whole library on
/// every page, yet must never lose a write made by another store/isolate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  UnifiedManga manga(String title, String id) => UnifiedManga(title: title,
    entries: {'readmanga': MangaEntry(source: 'readmanga', id: id, title: title)});
  final reader = manga('Reader series', '/reader');
  final other = manga('Other series', '/other');
  const chapter = Chapter(id: 'c-1', name: 'Глава 1');

  test('repeated page saves skip the full library decode', () async {
    final library = LibraryStore();
    await library.load();
    await library.add(other);
    await library.savePosition(reader, chapter, 'readmanga',
      pageIndex: 0, pageCount: 40);
    final before = library.debugFullReloads;
    for (var page = 1; page < 30; page++) {
      await library.savePosition(reader, chapter, 'readmanga',
        pageIndex: page, pageCount: 40);
    }
    expect(library.debugFullReloads, before);

    final restored = LibraryStore();
    await restored.load();
    expect(restored.get(reader)!.lastPageIndex, 29);
    expect(restored.has(other), true);
  });

  test('a write from another store is reloaded, not overwritten', () async {
    final library = LibraryStore();
    await library.load();
    await library.savePosition(reader, chapter, 'readmanga',
      pageIndex: 3, pageCount: 40);

    // Simulates the background isolate or another screen writing storage.
    final background = LibraryStore();
    await background.load();
    await background.add(other);
    await background.setStatus(reader, 'reading');

    final before = library.debugFullReloads;
    await library.savePosition(reader, chapter, 'readmanga',
      pageIndex: 4, pageCount: 40);
    expect(library.debugFullReloads, before + 1);

    final restored = LibraryStore();
    await restored.load();
    expect(restored.has(other), true);
    expect(restored.get(reader)!.status, 'reading');
    expect(restored.get(reader)!.lastPageIndex, 4);
  });

  test('untouched titles keep their sync revision across page saves', () async {
    final library = LibraryStore();
    await library.load();
    await library.add(other);
    await library.savePosition(reader, chapter, 'readmanga',
      pageIndex: 0, pageCount: 40);
    final prefs = await SharedPreferences.getInstance();
    int revision(String title) {
      final list = jsonDecode(prefs.getString(LibraryStore.storageKey)!) as List;
      return (list.cast<Map>().firstWhere((b) => b['title'] == title)
        ['syncEditedAt'] as num).toInt();
    }
    final otherRevision = revision(other.title);
    final readerRevision = revision(reader.title);
    for (var page = 1; page < 5; page++) {
      await library.savePosition(reader, chapter, 'readmanga',
        pageIndex: page, pageCount: 40);
    }
    expect(revision(other.title), otherRevision);
    expect(revision(reader.title), greaterThan(readerRevision));
  });

  test('malformed storage is never treated as known', () async {
    SharedPreferences.setMockInitialValues(
      {LibraryStore.storageKey: '{not json'});
    final library = LibraryStore();
    await library.load();
    final before = library.debugFullReloads;
    await library.savePosition(reader, chapter, 'readmanga',
      pageIndex: 1, pageCount: 40);
    // The hot path must fall back to the existing full reload behaviour.
    expect(library.debugFullReloads, before + 1);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/senkuro_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const senkuro = MangaEntry(source: 'senkuro', id: 'slug-a',
      title: 'Тайтл', coverUrl: 'https://example.com/cover.webp');
  const alternate = MangaEntry(source: 'readmanga', id: '/title',
      title: 'Тайтл');
  final book = UnifiedManga(title: 'Тайтл',
      entries: {'senkuro': senkuro, 'readmanga': alternate});

  test('verified score fills legacy bookmark without changing its state', () async {
    final library = LibraryStore();
    await library.setStatus(book, 'reading', preferredSource: 'readmanga');
    await library.setFavorite(book, true);
    const chapter = Chapter(id: '112', name: 'Глава 112');
    await library.savePosition(book, chapter, 'readmanga',
        pageIndex: 5, pageCount: 20);
    await library.markRead(book, chapter, 'readmanga');
    final before = library.get(book)!;
    expect(before.entries['senkuro']?.rating, null);
    final readKeys = Set<String>.of(before.readChapterKeys);
    final updated = await library.updateVerifiedRatings([
      const MangaEntry(source: 'senkuro', id: 'slug-a',
          title: 'Different online title', rating: 9.5),
    ]);
    expect(updated, 1);
    final saved = library.get(book)!;
    expect(saved.entries['senkuro']!.rating, 9.5);
    expect(saved.entries['senkuro']!.title, senkuro.title);
    expect(saved.entries['senkuro']!.coverUrl, senkuro.coverUrl);
    expect(saved.preferredSource, 'readmanga');
    expect(saved.lastChapterId, chapter.id);
    expect(saved.lastPageIndex, 5);
    expect(saved.favorite, true);
    expect(saved.status, 'reading');
    expect(saved.readChapterKeys, readKeys);
    final restored = LibraryStore();
    await restored.load();
    expect(restored.get(book)!.entries['senkuro']!.rating, 9.5);
    expect(restored.get(book)!.lastPageIndex, 5);
  });

  test('unknown, mismatched and invalid scores cannot mutate saved data',
      () async {
    final library = LibraryStore();
    await library.setStatus(book, 'planned');
    expect(await library.updateVerifiedRatings([
      const MangaEntry(source: 'senkuro', id: 'other',
          title: 'Other title', rating: 9.7),
      const MangaEntry(source: 'readmanga', id: 'slug-a',
          title: 'Wrong source', rating: 9.8),
      const MangaEntry(source: 'senkuro', id: 'slug-a',
          title: 'Invalid', rating: 0),
    ]), 0);
    expect(library.get(book)!.entries['senkuro']!.rating, null);
    expect(library.get(book)!.status, 'planned');
    expect(await library.updateVerifiedRatings([
      const MangaEntry(source: 'senkuro', id: 'slug-a',
          title: 'Verified', rating: 8.7),
    ]), 1);
    expect(await library.updateVerifiedRatings([
      const MangaEntry(source: 'senkuro', id: 'slug-a',
          title: 'No score'),
    ]), 0);
    expect(library.get(book)!.entries['senkuro']!.rating, 8.7);
  });

  test('Senkuro score-only batch returns a verified score, not chapter data',
      () async {
    var requests = 0;
    final source = SenkuroSource(client: MockClient((request) async {
      requests++;
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      expect(data['operationName'], 'batchMangaScores');
      expect((data['variables'] as Map)['slug0'], 'slug-a');
      return http.Response(jsonEncode({'data': {
        'a0': {'score': 9.6},
        for (var i = 1; i < 10; i++) 'a$i': {'score': null},
      }}), 200, headers: {'content-type': 'application/json'});
    }));
    final rated = await source.verifiedRatings([senkuro]);
    expect(requests, 1);
    expect(rated.single.rating, 9.6);
    expect(rated.single.id, senkuro.id);
    expect(rated.single.coverUrl, senkuro.coverUrl);
  });
}

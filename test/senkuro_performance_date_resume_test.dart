import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/senkuro_source.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/reading_suggestions.dart';

const _manga = MangaEntry(source: 'senkuro', id: 'source-slug',
    title: 'Проверка');

http.Response _ok(Object data) => http.Response(jsonEncode({'data': data}), 200,
    headers: {'content-type': 'application/json'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only real source dates are displayed; invalid values remain unknown', () {
    expect(sourceChapterDate('2025-10-30T09:15:00Z')?.year, 2025);
    expect(sourceChapterDate(1730280000)?.year, 2024);
    expect(sourceChapterDate('not a date'), isNull);
    expect(sourceChapterDate(''), isNull);
    expect(sourceChapterDate(null), isNull);
  });

  test('Senkuro chapter timestamp is parsed from supported date field', () async {
    final source = SenkuroSource(client: MockClient((req) async {
      final json = jsonDecode(req.body) as Map;
      if (json['operationName'] == 'fetchManga') {
        return _ok({'manga': {'branches': [{'id': 'first', 'primaryBranch': true}]}});
      }
      expect(json['operationName'], 'fetchMangaChapters');
      expect(json['query'].toString(), contains('createdAt'));
      return _ok({'mangaChapters': {
        'edges': [{'node': {'slug': 'c1', 'number': 1,
          'createdAt': '2025-10-30T09:15:00Z'}}],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      }});
    }));
    final detail = await source.detail(_manga);
    expect(detail.chapters.single.publishedAt?.year, 2025);
    expect(detail.chapters.single.publishedAt?.month, 10);
  });

  test('unsupported Senkuro date field falls back without losing chapters', () async {
    var dated = 0;
    var legacy = 0;
    final source = SenkuroSource(client: MockClient((req) async {
      final json = jsonDecode(req.body) as Map;
      if (json['operationName'] == 'fetchManga') {
        return _ok({'manga': {'branches': [{'id': 'first', 'primaryBranch': true}]}});
      }
      final withDate = json['query'].toString().contains('createdAt');
      if (withDate) {
        dated++;
        return http.Response(jsonEncode({'errors': [
          {'message': 'Cannot query field "createdAt" on type "MangaChapter".'}
        ]}), 200);
      }
      legacy++;
      return _ok({'mangaChapters': {
        'edges': [{'node': {'slug': 'c1', 'number': 1}}],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      }});
    }));
    final detail = await source.detail(_manga);
    expect(detail.chapters.single.name, 'Глава 1');
    expect(detail.chapters.single.publishedAt, isNull);
    expect(dated, 1);
    expect(legacy, 1);
  });

  test('concurrent title opens share one successful Senkuro request', () async {
    var detailRequests = 0;
    var chapterRequests = 0;
    final source = SenkuroSource(client: MockClient((req) async {
      final data = jsonDecode(req.body) as Map;
      if (data['operationName'] == 'fetchManga') {
        detailRequests++;
        return _ok({'manga': {'branches': [{'id': 'first', 'primaryBranch': true}]}});
      }
      chapterRequests++;
      return _ok({'mangaChapters': {
        'edges': [{'node': {'slug': 'c1', 'number': 1}}],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      }});
    }));
    final result = await Future.wait([
      source.detail(_manga), source.detail(_manga), source.detail(_manga),
    ]);
    expect(result.every((d) => d.chapters.length == 1), isTrue);
    await source.detail(_manga); // Cached, no duplicate network requests.
    expect(detailRequests, 1);
    expect(chapterRequests, 1);
  });

  test('confirmed newest chapter persists without overwriting reading place', () async {
    final library = LibraryStore();
    final book = UnifiedManga(title: _manga.title,
        entries: {'senkuro': _manga});
    await library.savePosition(book, const Chapter(id: '2', name: 'Глава 2'),
        'senkuro', pageIndex: 76, pageCount: 78);
    await library.recordLatestChapter(book, 'senkuro', const [
      Chapter(id: '2', name: 'Глава 2'),
      Chapter(id: '1', name: 'Глава 1'),
    ]);
    await library.load();
    final saved = library.get(book)!;
    expect(saved.lastPageIndex, 76);
    expect(saved.latestKnownChapterId, '2');
    expect(showContinueCard(saved), false);
    await library.recordLatestChapter(book, 'senkuro', const [
      Chapter(id: '3', name: 'Глава 3'),
      Chapter(id: '2', name: 'Глава 2'),
    ]);
    final newState = library.get(book)!;
    expect(newState.latestKnownChapterId, '3');
    expect(showContinueCard(newState), true);
  });
}

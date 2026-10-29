import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/remanga_source.dart';

// Synthetic fixtures based on the linked community adapter, not live responses.
const entry = MangaEntry(source: 'remanga', id: 'sample', title: 'Example');
const chapter = Chapter(id: '42', name: 'Chapter');
http.Response jsonResponse(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('popular/search wrappers, title variants, covers and encoded query', () async {
    final requests = <http.Request>[];
    final source = ReMangaSource(client: MockClient((request) async {
      requests.add(request);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('cookie'), isFalse);
      return jsonResponse({(request.url.path.endsWith('/catalog/') ? 'results' : 'content'): [
        {'dir': 'sample', 'main_name': 'Пример', 'cover': {'mid': '//cdn.example/a.jpg'}},
        {'slug': 'second', 'secondary_name': 'Second', 'img': '/b.jpg'},
        {'dir': '../bad', 'main_name': 'Bad'},
        {'dir': 'empty'}, null,
      ]});
    }));
    final popular = await source.popular();
    expect(popular.map((e) => e.id), ['sample', 'second']);
    expect(popular.first.coverUrl, 'https://cdn.example/a.jpg');
    expect(popular.last.coverUrl, 'https://remanga.org/b.jpg');
    expect(requests.first.url.queryParameters['ordering'], '-rating');
    expect((await source.search('a & б')).length, 2);
    expect(requests.last.url.queryParameters['query'], 'a & б');
    expect(requests.last.url.queryParameters['field'], 'titles');
  });

  test('detail paginates, deduplicates and filters anonymous chapter access', () async {
    final source = ReMangaSource(client: MockClient((request) async {
      if (request.url.path.endsWith('/sample/')) {
        return jsonResponse({'content': {
          'main_name': 'Example', 'branches': [{'id': 7}],
          'description': '<p>Readable description</p>',
          'genres': [{'name': 'Fantasy'}], 'img': {'high': '/cover.jpg'},
        }});
      }
      expect(request.url.queryParameters['branch_id'], '7');
      if (request.url.queryParameters['page'] == '2') {
        return jsonResponse({'content': [{'id': 1}, {'id': 8, 'chapter': '8'}], 'next': null});
      }
      return jsonResponse({'results': [
        {'id': 1, 'chapter': 1, 'name': 'Start', 'is_published': true, 'is_paid': false},
        {'id': 2, 'is_published': false},
        {'id': 3, 'is_paid': true, 'is_bought': false},
        {'id': 4, 'is_paid': true, 'is_bought': true},
        {'id': 5, 'is_paid': true, 'is_free_today': true},
        {'id': 6, 'is_locked': true, 'is_free_today': true},
        {'id': 7, 'is_paid': 'true'}, null,
      ], 'next': 'https://untrusted.example/ignored'});
    }));
    final detail = await source.detail(entry);
    expect(detail.chapters.map((c) => c.id), ['1', '5', '8']);
    expect(detail.chapters.first.name, 'Глава 1: Start');
    expect(detail.description, 'Readable description');
    expect(detail.genres, ['Fantasy']);
    expect(detail.entry.coverUrl, 'https://remanga.org/cover.jpg');
  });

  test('chapter pagination is bounded and does not follow next URLs', () async {
    var batches = 0;
    final source = ReMangaSource(client: MockClient((request) async {
      expect(request.url.host, 'api.remanga.org');
      if (request.url.path.endsWith('/sample/')) {
        return jsonResponse({'branches': [{'id': 1}]});
      }
      batches++;
      return jsonResponse({'results': [{'id': batches}], 'next': 'https://elsewhere.example/'});
    }));
    expect((await source.detail(entry)).chapters.length, ReMangaSource.maxChapterPages);
    expect(batches, ReMangaSource.maxChapterPages);
  });

  test('empty branches do not request chapters', () async {
    var calls = 0;
    final source = ReMangaSource(client: MockClient((_) async {
      calls++;
      return jsonResponse({'results': {'branches': []}});
    }));
    expect((await source.detail(entry)).chapters, isEmpty);
    expect(calls, 1);
  });

  test('nested page arrays preserve order and normalize HTTPS URLs', () async {
    final source = ReMangaSource(client: MockClient((_) async => jsonResponse({
      'content': {'pages': [[{'link': '//cdn.example/1.jpg'}],
        [{'link': '/2.jpg'}, [{'url': 'https://cdn.example/3.jpg'}]]]},
    })));
    final pages = await source.pages(chapter);
    expect(pages.map((p) => p.url), ['https://cdn.example/1.jpg',
      'https://remanga.org/2.jpg', 'https://cdn.example/3.jpg']);
    expect(pages.first.headers, {'Referer': 'https://remanga.org/'});
  });

  test('free-today chapter pages remain available anonymously', () async {
    final source = ReMangaSource(client: MockClient((_) async => jsonResponse({
      'results': {'is_paid': true, 'is_free_today': true,
        'pages': [{'link': 'https://cdn.example/free.jpg'}]},
    })));
    expect((await source.pages(chapter)).single.url, 'https://cdn.example/free.jpg');
  });

  test('chapter request failure does not return a partial playable list', () async {
    final source = ReMangaSource(client: MockClient((request) async {
      if (request.url.path.endsWith('/sample/')) {
        return jsonResponse({'content': {'branches': [{'id': 1}]}});
      }
      if (request.url.queryParameters['page'] == '1') {
        return jsonResponse({'results': [{'id': 1}], 'next': true});
      }
      return http.Response('restricted', 403);
    }));
    await expectLater(source.detail(entry), throwsA(isA<SourceException>()));
  });

  for (final data in [
    {'is_paid': true, 'is_bought': true, 'pages': [{'link': '/paid.jpg'}]},
    {'is_published': false, 'pages': [{'link': '/hidden.jpg'}]},
    {'is_locked': true, 'pages': [{'link': '/locked.jpg'}]},
    {'pages': []}, {'pages': 'bad'},
  ]) {
    test('unavailable pages fail clearly: $data', () async {
      final source = ReMangaSource(client: MockClient((_) async => jsonResponse({'content': data})));
      await expectLater(source.pages(chapter), throwsA(isA<SourceException>()));
    });
  }

  for (final url in ['http://cdn.example/a', 'javascript:alert(1)',
    'https://user:password@cdn.example/a', 'https://[bad', 'data:image/png;base64,a']) {
    test('reject unsafe page URL: $url', () async {
      final source = ReMangaSource(client: MockClient((_) async => jsonResponse({
        'pages': [{'link': url}],
      })));
      await expectLater(source.pages(chapter), throwsA(isA<SourceException>()));
    });
  }

  test('invalid title/chapter IDs never make requests', () async {
    final source = ReMangaSource(client: MockClient((_) async => fail('Unexpected request')));
    await expectLater(source.detail(const MangaEntry(source: 'remanga',
      id: 'https://elsewhere.example/', title: 'Bad')), throwsA(isA<SourceException>()));
    await expectLater(source.pages(const Chapter(id: '../42', name: 'Bad')), throwsA(isA<SourceException>()));
  });

  for (final body in ['not json', '[]', '{"content":{}}', '{"results":"bad"}']) {
    test('malformed catalog fails clearly: $body', () async {
      final source = ReMangaSource(client: MockClient((_) async => http.Response(body, 200)));
      await expectLater(source.popular(), throwsA(isA<SourceException>()));
    });
  }

  test('malformed detail and page payloads fail clearly', () async {
    final source = ReMangaSource(client: MockClient((_) async => jsonResponse({'content': []})));
    await expectLater(source.detail(entry), throwsA(isA<SourceException>()));
    await expectLater(source.pages(chapter), throwsA(isA<SourceException>()));
  });

  test('HTTP restrictions and network errors are source exceptions', () async {
    for (final status in [403, 429, 500]) {
      final source = ReMangaSource(client: MockClient((_) async => http.Response('', status)));
      await expectLater(source.popular(), throwsA(isA<SourceException>().having(
          (e) => e.message, 'message', contains('HTTP $status'))));
      await expectLater(source.detail(entry), throwsA(isA<SourceException>()));
      await expectLater(source.pages(chapter), throwsA(isA<SourceException>()));
    }
    final source = ReMangaSource(client: MockClient((_) async => throw http.ClientException('offline')));
    await expectLater(source.search('test'), throwsA(isA<SourceException>()));
    await expectLater(source.detail(entry), throwsA(isA<SourceException>()));
    await expectLater(source.pages(chapter), throwsA(isA<SourceException>()));
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/senkuro_source.dart';

// Synthetic fixtures for the existing query contract; no live API requests.
const _entry = MangaEntry(source: 'senkuro', id: 'sample', title: 'Example');
const _chapter = Chapter(id: 'chapter-1', name: 'Chapter');

http.Response _response(Object? body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _node(String slug, {Object? id, String title = 'Example',
    Object? cover = 'https://cdn.example/cover.webp'}) => {
  'node': {
    'slug': slug, 'id': id ?? slug,
    'titles': [{'lang': 'RU', 'content': title}],
    'cover': {'main': {'url': cover}},
  },
};

Object _catalog(List<Object?> edges) => {'data': {'mangas': {'edges': edges}}};

Matcher get _sourceError => throwsA(isA<SourceException>());

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() { closed = true; }
}

void main() {
  test('popular requests exact generic order and preserves source order', () async {
    final source = SenkuroSource(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.senkuro.com/graphql');
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('cookie'), isFalse);
      final body = jsonDecode(request.body) as Map;
      expect(body['operationName'], 'fetchMangas');
      expect(body['variables'], isEmpty);
      expect(body['query'], contains('field: POPULARITY_SCORE, direction: DESC'));
      expect(body['query'], isNot(contains('period')));
      return _response(_catalog([
        _node('z', title: 'Z')..['node']['score'] = 1,
        _node('a', title: 'A')..['node']['score'] = 10,
        _node('m', title: 'M')..['node']['score'] = 5,
      ]));
    }));
    final result = await source.popular();
    expect(result.map((e) => e.id), ['z', 'a', 'm']);
    expect(result.map((e) => e.title), ['Z', 'A', 'M']);
    expect(result.first.coverUrl, 'https://cdn.example/cover.webp');
  });

  test('stable deduplication recognizes both slug and source ID', () async {
    final source = SenkuroSource(client: MockClient((_) async => _response(_catalog([
      _node('first', id: '1', title: 'First'),
      _node('second', id: '2'),
      _node('first', id: '3', title: 'Duplicate slug'),
      _node('renamed', id: '2', title: 'Duplicate ID'),
      _node('', id: '1'),
      _node('', id: 4, title: 'ID fallback'),
      _node('', id: 4),
      _node('', id: 'first', title: 'Colliding fallback'),
      _node('last', id: '5'),
    ]))));
    final result = await source.popular();
    expect(result.map((e) => e.id), ['first', 'second', '4', 'last']);
    expect(result.first.title, 'First');
  });

  test('invalid nodes are skipped and empty connection is valid', () async {
    final source = SenkuroSource(client: MockClient((_) async => _response(_catalog([
      null, 1, {}, {'node': null}, {'node': []},
      _node('', id: {}), _node('no-title', title: '  '),
      {'node': {'slug': 'bad-title', 'titles': [{'content': 42}]}},
      {'node': {'slug': 'fallback', 'originalName': 'Original'}},
    ]))));
    expect((await source.popular()).single.title, 'Original');
    final empty = SenkuroSource(client: MockClient((_) async => _response(_catalog([]))));
    expect(await empty.popular(), isEmpty);
  });

  for (final body in [
    'not json', '[]', 'null', '{}', '{"data":null}', '{"data":[]}',
    '{"data":{"mangas":null}}', '{"data":{"mangas":[]}}',
    '{"data":{"mangas":{}}}', '{"data":{"mangas":{"edges":{}}}}',
    '{"data":{"mangas":{"edges":null}}}',
  ]) {
    test('malformed catalog is a source failure: $body', () async {
      final source = SenkuroSource(client: MockClient((_) async => http.Response(body, 200)));
      await expectLater(source.popular(), _sourceError);
    });
  }

  test('invalid UTF-8 is a source failure', () async {
    final source = SenkuroSource(client: MockClient((_) async => http.Response.bytes([0xff], 200)));
    await expectLater(source.popular(), _sourceError);
  });

  test('GraphQL errors reject partial data and expose the server error', () async {
    for (final data in [null, {'mangas': {'edges': [_node('partial')]}}]) {
      final source = SenkuroSource(client: MockClient((_) async => _response({
        'data': data, 'errors': [{'message': 'Field unavailable', 'path': ['mangas']}],
      })));
      await expectLater(source.popular(), throwsA(isA<SourceException>().having(
          (e) => e.message, 'message', contains('GraphQL: Field unavailable'))));
    }
  });

  test('malformed GraphQL errors never cause a type error', () async {
    for (final errors in [null, 'bad', {}, [null], [1], [{}], [{'message': 42}]]) {
      final source = SenkuroSource(client: MockClient((_) async => _response({
        'data': {'mangas': {'edges': []}}, 'errors': errors,
      })));
      await expectLater(source.popular(), _sourceError);
    }
    final source = SenkuroSource(client: MockClient((_) async => _response({
      'data': {'mangas': {'edges': []}}, 'errors': [],
    })));
    expect(await source.popular(), isEmpty);
  });

  test('HTTP restrictions fail once without retries', () async {
    for (final status in [302, 403, 429, 500]) {
      var calls = 0;
      final source = SenkuroSource(client: MockClient((_) async {
        calls++;
        return http.Response('restricted', status,
            headers: {'location': 'https://external.example/'});
      }));
      await expectLater(source.popular(), throwsA(isA<SourceException>().having(
          (e) => e.message, 'message', contains('HTTP $status'))));
      expect(calls, 1);
    }
  });

  test('timeout-like and client exceptions are source failures', () async {
    for (final error in [TimeoutException('offline'), http.ClientException('offline')]) {
      final source = SenkuroSource(client: MockClient((_) async => throw error));
      await expectLater(source.popular(), _sourceError);
      await expectLater(source.search('test'), _sourceError);
      await expectLater(source.detail(_entry), _sourceError);
      await expectLater(source.pages(_chapter), _sourceError);
    }
  });

  test('body deadline cancels an idle response stream', () async {
    // Use a short REAL timeout: Stopwatch is wall-clock based, whereas
    // testWidgets runs timers in fake async and can leave this future pending.
    var cancelled = false;
    final controller = StreamController<List<int>>(onCancel: () { cancelled = true; });
    final client = _StreamClient((_) async => http.StreamedResponse(controller.stream, 200));
    final source = SenkuroSource(client: client,
        timeout: const Duration(milliseconds: 120));
    await expectLater(source.popular(), _sourceError);
    expect(cancelled, isTrue);
    expect(client.closed, isFalse);
    await controller.close();
  });

  test('oversized declared and chunked bodies cancel before decoding', () async {
    const limit = 4 * 1024 * 1024;
    for (final declared in [true, false]) {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () { cancelled = true; });
      final client = _StreamClient((_) async => http.StreamedResponse(
          controller.stream, 200, contentLength: declared ? limit + 1 : null));
      final future = SenkuroSource(client: client).popular();
      if (!declared) {
        controller.add(List<int>.filled(limit, 32));
        controller.add([32]);
      }
      await expectLater(future, throwsA(isA<SourceException>().having(
          (e) => e.message, 'message', contains('слишком большой'))));
      // A declared oversized Content-Length is rejected before subscribing,
      // so there is no stream subscription to cancel. The streamed case
      // must cancel its active subscription on overflow.
      expect(cancelled, !declared);
      expect(client.closed, isFalse);
      await controller.close();
    }
  });

  for (final cover in [
    null, 42, {}, '', '/cover.webp', '//cdn.example/a', 'http://cdn.example/a',
    'javascript:alert(1)', 'data:image/png;base64,abc', 'https://[bad',
    'https://user:pass@cdn.example/a', 'https://cdn.example/a#fragment',
    'https://cdn.example/a b', 'https://cdn.example\\@localhost/a',
    'https:///a', 'https://localhost/a', 'https://127.0.0.1/a',
    'https://192.168.1.1/a', 'https://[::1]/a', 'https://host.local/a',
    'https://cdn.example:8080/a',
    'https://cdn.example:bad/a',
  ]) {
    test('unsafe cover is discarded without losing rank: $cover', () async {
      final source = SenkuroSource(client: MockClient((_) async =>
          _response(_catalog([_node('sample', cover: cover)]))));
      final result = await source.popular();
      expect(result.single.id, 'sample');
      expect(result.single.coverUrl, isEmpty);
    });
  }

  test('valid HTTPS cover retains path and query', () async {
    const url = 'https://images.senkuro.com/a.webp?width=300&format=webp';
    final source = SenkuroSource(client: MockClient((_) async =>
        _response(_catalog([_node('sample', cover: url)]))));
    expect((await source.popular()).single.coverUrl, url);
  });

  test('search variables, union filtering, title preference and empty query', () async {
    final operations = <String>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      operations.add(body['operationName'] as String);
      if (body['operationName'] == 'fetchMangas') return _response(_catalog([]));
      expect(body['variables'], {'query': 'a & б', 'first': 30});
      return _response({'data': {'search': {'edges': [
        {'node': {'__typename': 'SearchManga', 'slug': 'sample', 'titles': [
          {'lang': 'EN', 'content': 'English'}, {'lang': 'RU', 'content': 'Русский'},
        ]}},
        {'node': {'__typename': 'SearchUser', 'slug': 'user', 'originalName': 'User'}},
      ]}}});
    }));
    expect((await source.search('a & б')).single.title, 'Русский');
    expect(await source.search(''), isEmpty);
    expect(operations, ['search', 'fetchMangas']);
  });

  test('detail retains metadata, primary branch and chapter cursor ordering', () async {
    var batches = 0;
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      final variables = body['variables'];
      if (body['operationName'] == 'fetchManga') {
        expect(variables, {'slug': 'sample'});
        return _response({'data': {'manga': {
          'titles': [{'lang': 'RU', 'content': 'Пример'}], 'score': 8.5,
          'alternativeNames': [{'content': 'Alternate'}],
          'localizations': [{'lang': 'RU', 'description': [{'content': [{'text': 'Description'}]}]}],
          'labels': [{'titles': [{'content': 'Fantasy'}]}],
          'cover': {'main': {'url': 'https://cdn.example/detail.webp'}},
          'branches': [{'id': 'secondary'}, {'id': 'primary', 'primaryBranch': true}],
        }}});
      }
      expect(body['operationName'], 'fetchMangaChapters');
      expect(variables['branchId'], 'primary');
      expect(variables['orderBy'], {'field': 'NUMBER', 'direction': 'DESC'});
      expect(variables['after'], batches == 0 ? null : 'next');
      batches++;
      return _response({'data': {'mangaChapters': {
        'edges': [{'node': {'slug': 'chapter-$batches', 'number': 3 - batches}}],
        'pageInfo': {'hasNextPage': batches == 1, 'endCursor': 'next'},
      }}});
    }));
    final detail = await source.detail(_entry);
    expect(detail.entry.title, 'Пример');
    expect(detail.entry.coverUrl, 'https://cdn.example/detail.webp');
    expect(detail.rating, 8.5);
    expect(detail.alternativeNames, ['Alternate']);
    expect(detail.description, 'Description');
    expect(detail.genres, ['Fantasy']);
    expect(detail.chapters.map((c) => c.id), ['chapter-1', 'chapter-2']);
    expect(batches, 2);
  });

  test('pages sort numerically, prefer compressed and safely fall back', () async {
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body['operationName'], 'fetchMangaChapter');
      expect(body['variables'], {'slug': 'chapter-1', 'cdnQuality': 'auto'});
      return _response({'data': {'mangaChapter': {'pages': [
        {'number': 2, 'image': {'original': {'url': 'https://cdn.example/2'}}},
        {'number': 1, 'image': {'compress': {'url': 'https://cdn.example/1'},
          'original': {'url': 'https://cdn.example/original-1'}}},
        {'number': 3, 'image': {'compress': {'url': 'http://unsafe.example/3'},
          'original': {'url': 'https://cdn.example/3'}}},
        {'number': 4, 'image': {'original': {'url': 'https://localhost/4'}}},
      ]}}});
    }));
    final pages = await source.pages(_chapter);
    expect(pages.map((p) => p.url), [
      'https://cdn.example/1', 'https://cdn.example/2', 'https://cdn.example/3',
    ]);
    expect(pages.first.headers, {'Referer': 'https://senkuro.com/'});
  });

  test('detail without branches retains a safe existing cover', () async {
    final source = SenkuroSource(client: MockClient((request) async {
      expect((jsonDecode(request.body) as Map)['operationName'], 'fetchManga');
      return _response({'data': {'manga': {
        'originalName': {'content': 'Original'}, 'branches': [],
        'cover': {'main': {'url': 'http://unsafe.example/cover'}},
      }}});
    }));
    final detail = await source.detail(const MangaEntry(source: 'senkuro',
        id: 'sample', title: 'Example', coverUrl: 'https://cdn.example/old.webp'));
    expect(detail.chapters, isEmpty);
    expect(detail.entry.title, 'Original');
    expect(detail.entry.coverUrl, 'https://cdn.example/old.webp');
  });

  test('chapter pagination remains bounded to ten batches', () async {
    var batches = 0;
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['operationName'] == 'fetchManga') {
        return _response({'data': {'manga': {'branches': [{'id': 'branch'}]}}});
      }
      batches++;
      return _response({'data': {'mangaChapters': {
        'edges': [{'node': {'slug': 'chapter-$batches'}}],
        'pageInfo': {'hasNextPage': true, 'endCursor': 'cursor-$batches'},
      }}});
    }));
    expect((await source.detail(_entry)).chapters.length, 10);
    expect(batches, 10);
  });

  test('malformed search, detail, chapters and pages are source errors', () async {
    for (final data in [
      {}, {'search': []}, {'manga': []}, {'manga': {'branches': 'bad'}},
      {'manga': {'localizations': {}}}, {'mangaChapter': {'pages': {}}},
    ]) {
      final source = SenkuroSource(client: MockClient((_) async => _response({'data': data})));
      await expectLater(source.search('test'), _sourceError);
      await expectLater(source.detail(_entry), _sourceError);
      await expectLater(source.pages(_chapter), _sourceError);
    }
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      return _response({'data': body['operationName'] == 'fetchManga'
          ? {'manga': {'branches': [{'id': 'branch'}]}}
          : {'mangaChapters': null}});
    }));
    await expectLater(source.detail(_entry), _sourceError);
  });
}

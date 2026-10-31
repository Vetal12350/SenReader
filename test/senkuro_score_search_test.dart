import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/data/senkuro_source.dart';

http.Response ok(Map<String, dynamic> data) => http.Response(
  jsonEncode({'data': data}), 200,
  headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('verified manga scores appear on filtered catalog covers', () async {
    final operations = <String>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      operations.add(body['operationName'] as String);
      if (body['operationName'] == 'batchMangaScores') {
        expect((body['variables'] as Map)['slug0'], 'series-a');
        return ok({'a0': {'score': 9.2}, 'a1': {'score': 7.4}});
      }
      return ok({'mangaTachiyomiSearch': {'mangas': [
        {'id': 'a', 'slug': 'series-a',
          'titles': [{'lang': 'RU', 'content': 'Первая'}]},
        {'id': 'b', 'slug': 'series-b',
          'titles': [{'lang': 'RU', 'content': 'Вторая'}]},
      ]}});
    }));
    final result = await source.filteredCatalog(orderField: 'SCORE',
      withRatings: true);
    expect(result.map((e) => e.rating), [9.2, 7.4]);
    expect(operations, ['searchTachiyomiManga', 'batchMangaScores']);
  });

  test('failed score enrichment leaves actual titles, without fake ratings', () async {
    final source = SenkuroSource(client: MockClient((request) async {
      final op = (jsonDecode(request.body) as Map)['operationName'];
      if (op == 'batchMangaScores') return http.Response('Forbidden', 403);
      return ok({'mangaTachiyomiSearch': {'mangas': [
        {'id': 'a', 'slug': 'series-a',
          'titles': [{'lang': 'RU', 'content': 'Первая'}]},
      ]}});
    }));
    final result = await source.filteredCatalog(withRatings: true);
    expect(result.single.title, 'Первая');
    expect(result.single.rating, isNull);
  });

  test('English search falls back to Senkuro alternate search backend', () async {
    final calls = <String>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final op = (jsonDecode(request.body) as Map)['operationName'] as String;
      calls.add(op);
      if (op == 'search') return ok({'search': {'edges': []}});
      if (op == 'batchMangaScores') return ok({'a0': {'score': 8.1}});
      return ok({'mangaTachiyomiSearch': {'mangas': [
        {'id': 'english-id', 'slug': 'the-english-title',
          'titles': [{'lang': 'EN', 'content': 'The English Title'}]},
      ]}});
    }));
    final entries = await source.search('The English Title');
    expect(entries.single.title, 'The English Title');
    expect(entries.single.rating, 8.1);
    expect(calls, ['search', 'searchTachiyomiManga', 'batchMangaScores']);
  });
}

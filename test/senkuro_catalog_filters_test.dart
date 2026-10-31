import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/data/senkuro_source.dart';

void main() {
  test('Senkuro status/translation filters are sent to server as typed variables', () async {
    final requests = <Map<String, dynamic>>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      return http.Response(jsonEncode({'data': {'mangaTachiyomiSearch': {
        'mangas': [{'id': 'mid-1', 'slug': 'book', 'titles': [
          {'lang': 'RU', 'content': 'Книга'}],
          'cover': {'original': {'url': 'https://cdn.example/cover.webp'}}}]
      }}}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final books = await source.filteredCatalog(query: 'книга',
      type: 'MANHWA', status: 'ONGOING', translationStatus: 'ABANDONED');
    expect(books.single.title, 'Книга');
    expect(books.single.coverUrl, 'https://cdn.example/cover.webp');
    expect(requests.single['operationName'], 'searchTachiyomiManga');
    final values = requests.single['variables'] as Map<String, dynamic>;
    expect(values['query'], 'книга');
    expect(values['type'], {'include': ['MANHWA']});
    expect(values['status'], {'include': ['ONGOING']});
    expect(values['translationStatus'], {'include': ['ABANDONED']});
    expect(values['orderBy'], {'field': 'POPULARITY_SCORE', 'direction': 'DESC'});
  });

  test('unknown filters are rejected without network access', () async {
    var requests = 0;
    final source = SenkuroSource(client: MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    }));
    await expectLater(source.filteredCatalog(type: 'BAD'), throwsArgumentError);
    await expectLater(source.filteredCatalog(status: 'BAD'), throwsArgumentError);
    await expectLater(source.filteredCatalog(translationStatus: 'BAD'), throwsArgumentError);
    await expectLater(source.filteredCatalog(offset: -10), throwsArgumentError);
    expect(requests, 0);
  });
}

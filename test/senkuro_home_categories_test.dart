import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/data/senkuro_source.dart';

void main() {
  test('Senkuro browse uses genuine server order/type filters', () async {
    final requests = <Map<String, dynamic>>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      // Assertions after the mock request preserve a useful failure
      // message instead of being masked as a generic network exception.
      return http.Response(jsonEncode({'data': {'mangas': {'edges': [
        {'node': {
          'id': 'id-1', 'slug': 'series', 'type': 'MANHWA',
          'titles': [{'lang': 'RU', 'content': 'Серия'}],
          'labels': [{'titles': [{'lang': 'RU', 'content': 'Фэнтези'}]}],
          'cover': {'main': {'url': 'https://cdn.example/cover.webp'}},
        }}
      ]}}}), 200, headers: {'content-type': 'application/json'});
    }));
    final manhwa = await source.browseHome(type: 'MANHWA');
    expect(requests.first['operationName'], 'fetchMangas');
    expect(requests.first['query'], contains('type: \\$type'));
    expect(requests.first['query'], contains('orderBy:'));
    expect(manhwa.single.title, 'Серия');
    expect(manhwa.single.tags, ['Фэнтези']);
    expect(requests.single['variables']['type'], {'include': ['MANHWA']});
    expect(requests.single['variables']['orderField'], 'POPULARITY_SCORE');
    await source.browseHome(orderField: 'LAST_CHAPTER_AT');
    expect(requests.last['variables']['orderField'], 'LAST_CHAPTER_AT');
    expect(requests.last['variables']['type'], isNull);
  });

  test('unknown browse values are refused before calling API', () async {
    var calls = 0;
    final source = SenkuroSource(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(source.browseHome(type: 'UNKNOWN'),
      throwsArgumentError);
    await expectLater(source.browseHome(orderField: 'RANDOM'),
      throwsArgumentError);
    expect(calls, 0);
  });
}

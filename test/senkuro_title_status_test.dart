import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/senkuro_source.dart';

void main() {
  test('title statuses come from Senkuro metadata, not a saved reading state', () async {
    final operations = <String>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final operation = body['operationName'] as String;
      operations.add(operation);
      final response = operation == 'fetchManga'
          ? {'data': {'manga': {
              'slug': 'demo', 'titles': [{'lang': 'RU', 'content': 'Серия'}],
              'branches': [], 'labels': [],
            }}}
          : {'data': {'mangaTachiyomiInfo': {
              'status': 'ONGOING', 'translationStatus': 'FINISHED',
            }}};
      if (operation == 'fetchTachiyomiManga') {
        expect(body['variables'], {'mangaId': 'remote-id'});
      }
      return http.Response(jsonEncode(response), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final detail = await SenkuroSource(client: client).detail(
      const MangaEntry(source: 'senkuro', id: 'demo', title: 'Серия',
        remoteId: 'remote-id'));
    expect(detail.publicationStatus, 'Онгоинг');
    expect(detail.translationStatus, 'Переведено');
    expect(operations, ['fetchManga', 'fetchTachiyomiManga']);
  });

  test('missing status metadata does not prevent opening title', () async {
    final client = MockClient((request) async {
      final op = (jsonDecode(request.body) as Map)['operationName'];
      if (op != 'fetchManga') return http.Response('', 503);
      return http.Response(jsonEncode({'data': {'manga': {
        'slug': 'demo', 'titles': [{'lang': 'RU', 'content': 'Серия'}],
        'branches': [],
      }}}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final detail = await SenkuroSource(client: client).detail(
      const MangaEntry(source: 'senkuro', id: 'demo', title: 'Серия',
        remoteId: 'remote-id'));
    expect(detail.entry.title, 'Серия');
    expect(detail.publicationStatus, isNull);
    expect(detail.translationStatus, isNull);
  });
}

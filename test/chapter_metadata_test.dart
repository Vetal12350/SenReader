import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/core/chapter_updates.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/chapter_checker.dart';
import 'package:senreader/data/readmanga_source.dart';
import 'package:senreader/data/remanga_source.dart';
import 'package:senreader/data/senkuro_source.dart';

http.Response payload(Object data) => http.Response(jsonEncode(data), 200,
  headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('Senkuro retains volume/fraction metadata and checks every translation branch', () async {
    final requestedBranches = <String>[];
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['operationName'] == 'fetchManga') {
        return payload({'data': {'manga': {'titles': [{'lang': 'EN', 'content': 'Example'}],
          'branches': [{'id': 'first'}, {'id': 'second'}]}}});
      }
      final branch = (body['variables'] as Map)['branchId'] as String;
      requestedBranches.add(branch);
      return payload({'data': {'mangaChapters': {
        'edges': [{'node': {'slug': branch, 'volume': '02', 'number': '007.1200', 'name': branch}}],
        'pageInfo': {'hasNextPage': false}}}});
    }));
    final detail = await source.detail(const MangaEntry(source: 'senkuro', id: 'example', title: 'Example'));
    expect(requestedBranches, ['first', 'second']);
    expect(detail.chapters.map(canonicalChapterKey), ['v2:c7.12', 'v2:c7.12']);
  });

  test('ReadManga keeps volume before removing it from the display label', () async {
    final source = ReadMangaSource(client: MockClient((_) async => http.Response('''
      <h1>Example</h1><table><tr class="item-row"><td>
      <a class="chapter-link" href="/example/vol2/7">2 - 7.1200: Subtitle</a>
      </td></tr></table>
    ''', 200)));
    final detail = await source.detail(const MangaEntry(source: 'readmanga', id: '/example', title: 'Example'));
    expect(detail.chapters.single.name, 'Глава 7.1200: Subtitle');
    expect(canonicalChapterKey(detail.chapters.single), 'v2:c7.12');
  });

  test('ReManga checks all branches, keeps precise numbers and filters paid copies', () async {
    final branches = <String>[];
    final source = ReMangaSource(client: MockClient((request) async {
      if (request.url.path.endsWith('/example/')) {
        return payload({'content': {'branches': [{'id': 1}, {'id': 2}]}});
      }
      final branch = request.url.queryParameters['branch_id']!;
      branches.add(branch);
      return payload({'content': [{'id': int.parse(branch), 'tome': 2,
        'chapter': '7.120000000000000001', 'is_paid': branch == '1'}]});
    }));
    final detail = await source.detail(const MangaEntry(source: 'remanga', id: 'example', title: 'Example'));
    expect(branches, ['1', '2']);
    expect(detail.chapters.single.id, '2');
    expect(canonicalChapterKey(detail.chapters.single), 'v2:c7.120000000000000001');
  });

  test('paid-only ReManga has no readable detection, including purchased flags', () async {
    final source = ReMangaSource(client: MockClient((request) async {
      if (request.url.path.endsWith('/example/')) {
        return payload({'content': {'branches': [{'id': 1}]}});
      }
      return payload({'content': [
        {'id': 1, 'chapter': '1', 'is_paid': true, 'is_bought': true},
        {'id': 2, 'chapter': '2', 'is_locked': true},
      ]});
    }));
    final result = await ChapterChecker({'remanga': source}).check({
      'remanga': const MangaEntry(source: 'remanga', id: 'example', title: 'Example')},
      ChapterUpdateState(initialized: true));
    expect(result.newChapters, isEmpty);
    expect(result.state.seen, isEmpty);
  });

  test('a Senkuro listing followed by HTTP 403 page metadata cannot count as readable', () async {
    final source = SenkuroSource(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['operationName'] == 'fetchManga') {
        return payload({'data': {'manga': {'branches': [{'id': 'branch'}]}}});
      }
      if (body['operationName'] == 'fetchMangaChapters') {
        return payload({'data': {'mangaChapters': {'edges': [{'node': {
          'slug': 'restricted', 'volume': '1', 'number': '1'}}], 'pageInfo': {'hasNextPage': false}}}});
      }
      return http.Response('restricted', 403);
    }));
    final result = await ChapterChecker({'senkuro': source}).check({
      'senkuro': const MangaEntry(source: 'senkuro', id: 'example', title: 'Example')},
      ChapterUpdateState(initialized: true));
    expect(result.newChapters, isEmpty);
    expect(result.warnings.single, contains('403'));
  });

  test('ReadManga listing with an inaccessible reader is excluded', () async {
    final source = ReadMangaSource(client: MockClient((request) async {
      if (request.url.path == '/example') {
        return http.Response('<table><tr class="item-row"><td><a class="chapter-link" '
          'href="/example/vol1/1">1 - 1: Hidden</a></td></tr></table>', 200);
      }
      return http.Response('restricted', 403);
    }));
    final result = await ChapterChecker({'readmanga': source}).check({
      'readmanga': const MangaEntry(source: 'readmanga', id: '/example', title: 'Example')},
      ChapterUpdateState(initialized: true));
    expect(result.newChapters, isEmpty);
    expect(result.warnings.single, contains('403'));
  });
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

/// Public catalog adapter. No credentials, paywall circumvention or CAPTCHA bypass.
/// GraphQL schema based on the Apache-2.0 mangayomi-ru-sources adapter.
class SenkuroSource implements MangaSource {
  static const _api = 'https://api.senkuro.com/graphql';
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {'Referer': 'https://senkuro.com/'};

  static const _catalogQuery = r'''
query fetchMangas($first: Int = 30) {
  mangas(first: $first, orderBy: {field: POPULARITY_SCORE, direction: DESC}) {
    edges { node { id slug titles { lang content } originalName { lang content }
      cover { main: resize(width: 300, height: 420, format: WEBP) { url } } } }
  }
}''';
  static const _searchQuery = r'''
query search($query: String!, $first: Int = 30) {
  search(query: $query, type: MANGA, first: $first) {
    edges { node { __typename ... on SearchManga {
      id slug originalName titles { lang content }
      cover { main: resize(width: 300, height: 420, format: WEBP) { url } }
    } } }
  }
}''';
  static const _detailQuery = r'''
query fetchManga($slug: String!) {
  manga(slug: $slug) {
    slug score titles { lang content } originalName { lang content }
    alternativeNames { lang content }
    localizations { lang description { __typename
      ... on TiptapNodeText { text }
      ... on TiptapNodeNestedBlock { content { __typename ... on TiptapNodeText { text } } }
    } }
    labels { titles { lang content } }
    cover { main: resize(width: 600, height: 850, format: WEBP) { url } }
    branches { id primaryBranch chapters }
  }
}''';
  static const _chaptersQuery = r'''
query fetchMangaChapters($branchId: ID!, $after: String, $orderBy: MangaChapterOrder!) {
  mangaChapters(first: 100, branchId: $branchId, after: $after, orderBy: $orderBy) {
    edges { node { id slug name number volume } }
    pageInfo { hasNextPage endCursor }
  }
}''';
  static const _pagesQuery = r'''
query fetchMangaChapter($slug: String!, $cdnQuality: String) {
  mangaChapter(slug: $slug) {
    pages(cdnQuality: $cdnQuality) { number image {
      original { url }
      compress: resize(width: 1200, quality: 80, format: WEBP) { url }
    } }
  }
}''';

  Future<Map<String, dynamic>> _gql(String operation, String query, Map<String, dynamic> variables) async {
    late http.Response response;
    try {
      response = await http.post(Uri.parse(_api),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/graphql-response+json, application/json',
            'Origin': 'https://senkuro.com',
            'Referer': 'https://senkuro.com/',
          },
          body: jsonEncode({'operationName': operation, 'query': query, 'variables': variables}),
      ).timeout(const Duration(seconds: 18));
    } catch (e) {
      throw SourceException('Нет соединения с Senkuro ($e)');
    }
    if (response.statusCode != 200) {
      throw SourceException('HTTP ${response.statusCode}. Возможно, доступ ограничен.');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic>) throw SourceException('Некорректный ответ Senkuro');
    if (json['errors'] is List && (json['errors'] as List).isNotEmpty) {
      throw SourceException('GraphQL: ${(json['errors'] as List).first['message']}');
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) throw SourceException('Нет данных в ответе Senkuro');
    return data;
  }

  static String _title(dynamic titles, dynamic original) {
    if (titles is List && titles.isNotEmpty) {
      final matches = titles.whereType<Map>().toList();
      for (final lang in ['RU', 'EN']) {
        for (final title in matches) {
          if (title['lang'] == lang && title['content'] is String) return title['content'] as String;
        }
      }
      if (matches.isNotEmpty && matches.first['content'] != null) return '${matches.first['content']}';
    }
    if (original is Map && original['content'] != null) return '${original['content']}';
    if (original is String) return original;
    return '';
  }

  static String _cover(dynamic json) =>
      json is Map && json['main'] is Map ? '${json['main']['url'] ?? ''}' : '';

  List<MangaEntry> _parseNodes(dynamic edges) {
    if (edges is! List) return [];
    return edges.map((edge) {
      final n = edge is Map ? edge['node'] : null;
      if (n is! Map) return null;
      final title = _title(n['titles'], n['originalName']);
      final id = '${n['slug'] ?? n['id'] ?? ''}';
      if (id.isEmpty || title.isEmpty) return null;
      return MangaEntry(source: key, id: id, title: title, coverUrl: _cover(n['cover']));
    }).whereType<MangaEntry>().toList();
  }

  @override Future<List<MangaEntry>> popular() async {
    final data = await _gql('fetchMangas', _catalogQuery, {});
    return _parseNodes((data['mangas'] as Map?)?['edges']);
  }

  @override Future<List<MangaEntry>> search(String query) async {
    if (query.isEmpty) return popular();
    final data = await _gql('search', _searchQuery, {'query': query, 'first': 30});
    return _parseNodes((data['search'] as Map?)?['edges']);
  }

  static String _flatten(dynamic input) {
    if (input is List) return input.map(_flatten).where((x) => x.isNotEmpty).join('\n');
    if (input is Map) return '${input['text'] ?? ''}\n${_flatten(input['content'])}'.trim();
    return '';
  }

  @override Future<MangaDetail> detail(MangaEntry entry) async {
    final data = await _gql('fetchManga', _detailQuery, {'slug': entry.id});
    final m = data['manga'];
    if (m is! Map) throw SourceException('Произведение недоступно на Senkuro');
    final locs = (m['localizations'] as List?) ?? [];
    dynamic loc;
    for (final language in ['RU', 'EN']) {
      for (final value in locs) {
        if (value is Map && value['lang'] == language && value['description'] != null) {
          loc = value; break;
        }
      }
      if (loc != null) break;
    }
    final branches = ((m['branches'] as List?) ?? []).whereType<Map>().toList()
      ..sort((a, b) => (b['primaryBranch'] == true ? 1 : 0).compareTo(a['primaryBranch'] == true ? 1 : 0));
    final chapters = <Chapter>[];
    // Prefer the primary Russian branch; avoid mixing translations in v0.1.
    if (branches.isNotEmpty) {
      String? cursor;
      for (var batch = 0; batch < 10; batch++) {
        final result = await _gql('fetchMangaChapters', _chaptersQuery, {
          'branchId': '${branches.first['id']}',
          'after': cursor,
          'orderBy': {'field': 'NUMBER', 'direction': 'DESC'},
        });
        final conn = result['mangaChapters'];
        if (conn is! Map) break;
        for (final edge in (conn['edges'] as List? ?? [])) {
          final n = edge is Map ? edge['node'] : null;
          if (n is! Map) continue;
          final id = '${n['slug'] ?? n['id'] ?? ''}';
          if (id.isEmpty) continue;
          final number = n['number'] ?? '?';
          final subtitle = (n['name'] is String && (n['name'] as String).isNotEmpty) ? ': ${n['name']}' : '';
          final volume = n['volume'];
          final suffix = volume == null || '$volume' == '0' ? '' : ' (т. $volume)';
          chapters.add(Chapter(id: id, name: 'Глава $number$subtitle$suffix'));
        }
        final pageInfo = conn['pageInfo'];
        if (pageInfo is! Map || pageInfo['hasNextPage'] != true) break;
        cursor = pageInfo['endCursor'] as String?;
        if (cursor == null || cursor.isEmpty) break;
      }
    }
    return MangaDetail(
      entry: MangaEntry(source: key, id: entry.id, title: _title(m['titles'], m['originalName']),
        coverUrl: _cover(m['cover']).isNotEmpty ? _cover(m['cover']) : entry.coverUrl),
      chapters: chapters,
      description: loc is Map ? _flatten(loc['description']).trim() : '',
      genres: (m['labels'] as List? ?? []).whereType<Map>().map((e) => _title(e['titles'], null)).where((s) => s.isNotEmpty).take(12).toList(),
      rating: tenPointScore(m['score']),
      alternativeNames: (m['alternativeNames'] as List? ?? [])
          .whereType<Map>().map((item) => '${item['content'] ?? ''}')
          .where((name) => name.trim().isNotEmpty).take(6).toList(),
    );
  }

  @override Future<List<PageImage>> pages(Chapter chapter) async {
    final data = await _gql('fetchMangaChapter', _pagesQuery, {'slug': chapter.id, 'cdnQuality': 'auto'});
    final m = data['mangaChapter'];
    final pages = m is Map ? (m['pages'] as List? ?? []) : [];
    final sorted = pages.whereType<Map>().toList()
      ..sort((a, b) => ((a['number'] as num?) ?? 0).compareTo((b['number'] as num?) ?? 0));
    final result = <PageImage>[];
    for (final p in sorted) {
      final img = p['image'];
      if (img is! Map) continue;
      final compressed = img['compress'];
      final original = img['original'];
      final url = compressed is Map && compressed['url'] != null ? '${compressed['url']}'
          : original is Map ? '${original['url'] ?? ''}' : '';
      if (url.startsWith('https://')) result.add(PageImage(url, headers: imageHeaders));
    }
    return result;
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

/// Public catalog adapter. No credentials, paywall circumvention or CAPTCHA bypass.
/// GraphQL schema based on the Apache-2.0 mangayomi-ru-sources adapter.
class SenkuroSource implements MangaSource {
  SenkuroSource({http.Client? client}) : _client = client;
  final http.Client? _client;
  static const _timeout = Duration(seconds: 18);
  static const _maxResponseBytes = 4 * 1024 * 1024;
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
    // An injected client belongs to the caller. Default clients live for one
    // request, including body consumption, and are always closed.
    final client = _client ?? http.Client();
    final elapsed = Stopwatch()..start();
    try {
      final request = http.Request('POST', Uri.parse(_api))
        ..followRedirects = false
        ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'application/graphql-response+json, application/json',
            'Origin': 'https://senkuro.com',
            'Referer': 'https://senkuro.com/',
          })
        ..body = jsonEncode({'operationName': operation, 'query': query, 'variables': variables});
      final response = await client.send(request).timeout(_timeout);
      final iterator = StreamIterator(response.stream);
      final bytes = <int>[];
      try {
        if (response.statusCode != 200) {
          throw SourceException('Senkuro: HTTP ${response.statusCode}. Возможно, доступ ограничен.');
        }
        if ((response.contentLength ?? 0) > _maxResponseBytes) {
          throw SourceException('Senkuro: ответ слишком большой.');
        }
        while (true) {
          final remaining = _timeout - elapsed.elapsed;
          if (remaining <= Duration.zero) throw TimeoutException('Senkuro');
          if (!await iterator.moveNext().timeout(remaining)) break;
          if (bytes.length + iterator.current.length > _maxResponseBytes) {
            throw SourceException('Senkuro: ответ слишком большой.');
          }
          bytes.addAll(iterator.current);
        }
      } finally {
        await iterator.cancel();
      }
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) throw _invalidResponse();
      final errors = json['errors'];
      if (json.containsKey('errors')) {
        if (errors is! List) throw _invalidResponse();
        if (errors.isNotEmpty) {
          // Never silently present partial GraphQL data as a complete ranking.
          final first = errors.first;
          if (first is! Map || first['message'] is! String) throw _invalidResponse();
          final message = (first['message'] as String).replaceAll(RegExp(r'[\r\n\t]'), ' ');
          throw SourceException('Senkuro GraphQL: ${message.length > 200 ? message.substring(0, 200) : message}');
        }
      }
      final data = json['data'];
      if (data is! Map<String, dynamic>) throw _invalidResponse();
      return data;
    } on SourceException {
      rethrow;
    } on FormatException {
      throw _invalidResponse();
    } catch (_) {
      throw SourceException('Senkuro: нет соединения или время ожидания истекло.');
    } finally {
      if (_client == null) client.close();
    }
  }

  static SourceException _invalidResponse() => SourceException('Некорректный ответ Senkuro');
  static String _text(dynamic value) => value is String ? value.trim() : '';
  static String _id(dynamic value) => value is int ? '$value' : _text(value);
  static List _list(dynamic value) {
    if (value is! List) throw _invalidResponse();
    return value;
  }
  static List _optionalList(dynamic value) => value == null ? [] : _list(value);
  static List _edges(dynamic connection) {
    if (connection is! Map) throw _invalidResponse();
    return _list(connection['edges']);
  }

  static String _title(dynamic titles, dynamic original) {
    if (titles is List && titles.isNotEmpty) {
      final matches = titles.whereType<Map>().toList();
      for (final lang in ['RU', 'EN']) {
        for (final title in matches) {
          if (title['lang'] == lang && _text(title['content']).isNotEmpty) return _text(title['content']);
        }
      }
      for (final title in matches) {
        if (_text(title['content']).isNotEmpty) return _text(title['content']);
      }
    }
    if (original is Map) return _text(original['content']);
    if (original is String) return original.trim();
    return '';
  }

  static String _image(dynamic value) {
    if (value is! String || RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(value)) return '';
    try {
      return _httpsImage(value);
    } on FormatException {
      return '';
    }
  }

  static String _httpsImage(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
        uri.hasFragment || (uri.hasPort && uri.port != 443)) return '';
    // CDN hostnames may change. Accept HTTPS DNS names, but never IP literals,
    // single-label/local hosts, credentials, fragments or ambiguous URLs.
    final host = uri.host.toLowerCase();
    final labels = host.split('.');
    if (labels.length < 2 || !RegExp(r'^[a-z]{2,}$').hasMatch(labels.last) ||
        ['localhost', 'local', 'internal', 'lan', 'home', 'test', 'invalid'].contains(labels.last) ||
        labels.any((label) => !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label))) return '';
    return uri.toString();
  }

  static String _cover(dynamic json) =>
      json is Map && json['main'] is Map ? _image(json['main']['url']) : '';

  List<MangaEntry> _parseNodes(dynamic edges) {
    final seenSlugs = <String>{};
    final seenIds = <String>{};
    final seenEntryIds = <String>{};
    return _list(edges).map((edge) {
      final n = edge is Map ? edge['node'] : null;
      if (n is! Map || (n['__typename'] != null && n['__typename'] != 'SearchManga')) return null;
      final title = _title(n['titles'], n['originalName']);
      final slug = _text(n['slug']);
      final sourceId = _id(n['id']);
      final id = slug.isNotEmpty ? slug : sourceId;
      if (id.isEmpty || title.isEmpty) return null;
      final duplicate = seenEntryIds.contains(id) ||
          (slug.isNotEmpty && seenSlugs.contains(slug)) ||
          (sourceId.isNotEmpty && seenIds.contains(sourceId));
      if (slug.isNotEmpty) seenSlugs.add(slug);
      if (sourceId.isNotEmpty) seenIds.add(sourceId);
      if (duplicate) return null;
      seenEntryIds.add(id);
      return MangaEntry(source: key, id: id, title: title, coverUrl: _cover(n['cover']));
    }).whereType<MangaEntry>().toList();
  }

  /// Generic POPULARITY_SCORE DESC, not verified time-window read counts.
  /// Retains server order; first occurrence wins when slug or source ID repeats.
  @override Future<List<MangaEntry>> popular() async {
    final data = await _gql('fetchMangas', _catalogQuery, {});
    return _parseNodes(_edges(data['mangas']));
  }

  @override Future<List<MangaEntry>> search(String query) async {
    if (query.isEmpty) return popular();
    final data = await _gql('search', _searchQuery, {'query': query, 'first': 30});
    return _parseNodes(_edges(data['search']));
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
    final locs = _optionalList(m['localizations']);
    dynamic loc;
    for (final language in ['RU', 'EN']) {
      for (final value in locs) {
        if (value is Map && value['lang'] == language && value['description'] != null) {
          loc = value; break;
        }
      }
      if (loc != null) break;
    }
    final branches = _optionalList(m['branches']).whereType<Map>().toList()
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
        for (final edge in _edges(conn)) {
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
        final pageInfo = (conn as Map)['pageInfo'];
        if (pageInfo is! Map || pageInfo['hasNextPage'] is! bool) throw _invalidResponse();
        if (pageInfo['hasNextPage'] != true) break;
        final next = _text(pageInfo['endCursor']);
        if (next.isEmpty || next == cursor) throw _invalidResponse();
        cursor = next;
      }
    }
    return MangaDetail(
      entry: MangaEntry(source: key, id: entry.id, title: _title(m['titles'], m['originalName']),
        coverUrl: _cover(m['cover']).isNotEmpty ? _cover(m['cover']) : _image(entry.coverUrl)),
      chapters: chapters,
      description: loc is Map ? _flatten(loc['description']).trim() : '',
      genres: _optionalList(m['labels']).whereType<Map>().map((e) => _title(e['titles'], null)).where((s) => s.isNotEmpty).take(12).toList(),
      rating: tenPointScore(m['score']),
      alternativeNames: _optionalList(m['alternativeNames'])
          .whereType<Map>().map((item) => _text(item['content']))
          .where((name) => name.trim().isNotEmpty).take(6).toList(),
    );
  }

  @override Future<List<PageImage>> pages(Chapter chapter) async {
    final data = await _gql('fetchMangaChapter', _pagesQuery, {'slug': chapter.id, 'cdnQuality': 'auto'});
    final m = data['mangaChapter'];
    if (m is! Map) throw _invalidResponse();
    final pages = _list(m['pages']);
    final sorted = pages.whereType<Map>().toList()
      ..sort((a, b) => (a['number'] is num ? a['number'] as num : 0)
          .compareTo(b['number'] is num ? b['number'] as num : 0));
    final result = <PageImage>[];
    for (final p in sorted) {
      final img = p['image'];
      if (img is! Map) continue;
      final compressed = img['compress'];
      final original = img['original'];
      var url = compressed is Map ? _image(compressed['url']) : '';
      if (url.isEmpty && original is Map) url = _image(original['url']);
      if (url.isNotEmpty) result.add(PageImage(url, headers: imageHeaders));
    }
    return result;
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

class SenkuroCatalogLabel {
  const SenkuroCatalogLabel(this.slug, this.title, this.rootId);
  final String slug;
  final String title;
  final String rootId;
}

/// Public catalog adapter. No credentials, paywall circumvention or CAPTCHA bypass.
/// GraphQL schema based on the Apache-2.0 mangayomi-ru-sources adapter.
class SenkuroSource implements MangaSource {
  SenkuroSource({http.Client? client,
      Duration timeout = const Duration(seconds: 18)})
      : _client = client, _timeout = timeout;
  final http.Client? _client;
  final Duration _timeout;
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _api = 'https://api.senkuro.com/graphql';
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {'Referer': 'https://senkuro.com/'};

  static const _catalogQuery = r'''
query fetchMangas($first: Int = 30) {
  mangas(first: $first, orderBy: {field: POPULARITY_SCORE, direction: DESC}) {
    edges { node { id slug score titles { lang content } originalName { lang content }
      labels { titles { lang content } }
      cover { main: resize(width: 300, height: 420, format: WEBP) { url } } } }
  }
}''';
  // Server-backed categories, following Senkuro's documented public browse
  // filters. Keep this separate from the existing stable popularity query.
  static const _homeQuery = r'''
query fetchMangas($first: Int = 18, $type: MangaTypeFilter,
    $orderField: MangaOrderField = POPULARITY_SCORE) {
  mangas(first: $first, type: $type,
    orderBy: {field: $orderField, direction: DESC}) {
    edges { node { id slug type score titles { lang content }
      originalName { lang content } labels { titles { lang content } }
      cover { main: resize(width: 300, height: 420, format: WEBP) { url } } } }
  }
}''';

  /// Public, explicitly ordered Senkuro manga browse categories.
  /// Unknown values are rejected rather than sent to a remote API.
  Future<List<MangaEntry>> browseHome({
      String? type, String orderField = 'POPULARITY_SCORE', int first = 18}) async {
    if (type != null && !const {'MANGA', 'MANHWA', 'MANHUA'}.contains(type)) {
      throw ArgumentError.value(type, 'type', 'Unsupported Senkuro type');
    }
    if (!const {'POPULARITY_SCORE', 'LAST_CHAPTER_AT', 'CREATED_AT'}
        .contains(orderField)) {
      throw ArgumentError.value(orderField, 'orderField', 'Unsupported order');
    }
    if (first < 1 || first > 30) throw ArgumentError.value(first, 'first');
    final data = await _gql('fetchMangas', _homeQuery, {
      'first': first, 'type': type == null ? null : {'include': [type]},
      'orderField': orderField,
    });
    return _parseNodes(_edges(data['mangas']));
  }

  // Public search/filter operation used by the Senkuro extensions.
  // Never interpolate untrusted values directly into the GraphQL document.
  static const _labelsQuery = r'''
query fetchTachiyomiSearchFilters {
  mangaTachiyomiSearchFilters {
    labels { id rootId slug titles { lang content } }
  }
}''';

  Future<List<SenkuroCatalogLabel>> catalogLabels() async {
    final data = await _gql('fetchTachiyomiSearchFilters', _labelsQuery, {});
    final filters = data['mangaTachiyomiSearchFilters'];
    if (filters is! Map || filters['labels'] is! List) throw _invalidResponse();
    final seen = <String>{};
    final labels = <SenkuroCatalogLabel>[];
    for (final label in filters['labels'] as List) {
      if (label is! Map) continue;
      final slug = _text(label['slug']);
      final title = _title(label['titles'], null);
      if (slug.isEmpty || title.isEmpty || !seen.add(slug)) continue;
      labels.add(SenkuroCatalogLabel(slug, title, _text(label['rootId'])));
    }
    labels.sort((a, b) => a.title.compareTo(b.title));
    return labels;
  }

  static const _filteredQuery = r'''
query searchTachiyomiManga(
  $query: String,
  $type: MangaTachiyomiSearchTypeFilter,
  $status: MangaTachiyomiSearchStatusFilter,
  $label: MangaTachiyomiSearchLabelFilter,
  $translationStatus: MangaTachiyomiSearchTranslationStatusFilter,
  $orderBy: MangaTachiyomiOrder,
  $offset: Int
) {
  mangaTachiyomiSearch(query: $query, type: $type, status: $status,
      label: $label, translationStatus: $translationStatus, orderBy: $orderBy,
      offset: $offset) {
    mangas { id slug originalName { lang content } titles { lang content }
      cover { original { url } } }
  }
}''';

  Future<List<MangaEntry>> filteredCatalog({
      String query = '', String? type, String? status,
      String? translationStatus, String? label, int offset = 0}) async {
    if (type != null && !const {'MANGA', 'MANHWA', 'MANHUA',
        'COMICS', 'OEL_MANGA', 'RU_MANGA'}.contains(type)) {
      throw ArgumentError.value(type, 'type');
    }
    if (status != null && !const {'ANNOUNCE', 'ONGOING', 'FINISHED',
        'HIATUS', 'CANCELLED'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    if (translationStatus != null && !const {'IN_PROGRESS', 'FINISHED',
        'FROZEN', 'ABANDONED'}.contains(translationStatus)) {
      throw ArgumentError.value(translationStatus, 'translationStatus');
    }
    if (label != null && (label.length > 120 ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(label))) {
      throw ArgumentError.value(label, 'label');
    }
    if (offset < 0 || offset > 990 || offset % 10 != 0) {
      throw ArgumentError.value(offset, 'offset');
    }
    final allEdges = <Map<String, dynamic>>[];
    // The public Tachiyomi search API returns pages of at most 10 items.
    // Keep the first 30 server-ordered results, without claiming all titles.
    for (var page = 0; page < 3; page++) {
      final data = await _gql('searchTachiyomiManga', _filteredQuery, {
        'query': query.trim().isEmpty ? null : query.trim(),
        'type': type == null ? null : {'include': [type]},
        'status': status == null ? null : {'include': [status]},
        'label': label == null ? null : {'include': [label]},
        'translationStatus': translationStatus == null
            ? null : {'include': [translationStatus]},
        'orderBy': {'field': 'POPULARITY_SCORE', 'direction': 'DESC'},
        'offset': offset + page * 10,
      });
      final connection = data['mangaTachiyomiSearch'];
      if (connection is! Map || connection['mangas'] is! List) {
        throw _invalidResponse();
      }
      final pageNodes = _list(connection['mangas']);
      allEdges.addAll(pageNodes.map((node) => {'node': node}));
      if (pageNodes.length < 10) break;
    }
    return _parseNodes(allEdges);
  }

  static const _searchQuery = r'''
query search($query: String!, $first: Int = 30) {
  search(query: $query, type: MANGA, first: $first) {
    edges { node { __typename ... on SearchManga {
      id slug score originalName titles { lang content }
      cover { main: resize(width: 300, height: 420, format: WEBP) { url } }
    } } }
  }
}''';
  static const _detailQuery = r'''
query fetchManga($slug: String!) {
  manga(slug: $slug) {
    id slug score titles { lang content } originalName { lang content }
    alternativeNames { lang content }
    localizations { lang description { __typename
      ... on TiptapNodeText { text }
      ... on TiptapNodeNestedBlock { content { __typename ... on TiptapNodeText { text } } }
    } }
    labels { titles { lang content } }
    mainStaff { roles person { name } }
    cover { main: resize(width: 600, height: 850, format: WEBP) { url } }
    branches { id primaryBranch chapters }
  }
}''';
  // Optional metadata, from Senkuro's public Tachiyomi-compatible API.
  // A metadata failure must not make readable chapters disappear.
  static const _statusQuery = r'''
query fetchTachiyomiManga($mangaId: ID!) {
  mangaTachiyomiInfo(mangaId: $mangaId) {
    status translationStatus
  }
}''';

  static String? _publicationLabel(dynamic value) => switch (value) {
    'ANNOUNCE' => 'Анонс',
    'ONGOING' => 'Онгоинг',
    'FINISHED' => 'Выпущено',
    'HIATUS' => 'Приостановлено',
    'CANCELLED' => 'Отменено',
    _ => null,
  };
  static String? _translationLabel(dynamic value) => switch (value) {
    'IN_PROGRESS' => 'Переводится',
    'FINISHED' => 'Переведено',
    'FROZEN' => 'Заморожено',
    'ABANDONED' => 'Заброшено',
    _ => null,
  };

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
      // Reject oversized/failed responses before opening a stream iterator.
      // Cancelling an iterator which was never subscribed can await forever.
      if (response.statusCode != 200) {
        throw SourceException('Senkuro: HTTP ${response.statusCode}. Возможно, доступ ограничен.');
      }
      if ((response.contentLength ?? 0) > _maxResponseBytes) {
        throw SourceException('Senkuro: ответ слишком большой.');
      }
      final iterator = StreamIterator(response.stream);
      final bytes = <int>[];
      try {
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
      json is Map && json['main'] is Map ? _image(json['main']['url'])
        : json is Map && json['original'] is Map
          ? _image(json['original']['url']) : '';

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
      return MangaEntry(source: key, id: id, remoteId: sourceId, title: title,
        rating: tenPointScore(n['score']),
        coverUrl: _cover(n['cover']),
        tags: _optionalList(n['labels']).whereType<Map>()
            .map((label) => _title(label['titles'], null))
            .where((tag) => tag.isNotEmpty)
            .toSet().take(24).toList());
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
    Map<dynamic, dynamic> metadata = const {};
    final metadataId = entry.remoteId.isNotEmpty ? entry.remoteId : _id(m['id']);
    if (metadataId.isNotEmpty) {
      try {
        final statusInfo = await _gql('fetchTachiyomiManga',
          _statusQuery, {'mangaId': metadataId});
        if (statusInfo['mangaTachiyomiInfo'] is Map) {
          metadata = statusInfo['mangaTachiyomiInfo'] as Map;
        }
      } catch (_) {
        // Status labels are optional; chapter and cover loading remain usable.
      }
    }
    return MangaDetail(
      publicationStatus: _publicationLabel(metadata['status']),
      translationStatus: _translationLabel(metadata['translationStatus']),
      entry: MangaEntry(source: key, id: entry.id, remoteId: metadataId,
        title: _title(m['titles'], m['originalName']),
        coverUrl: _cover(m['cover']).isNotEmpty ? _cover(m['cover']) : _image(entry.coverUrl)),
      chapters: chapters,
      description: loc is Map ? _flatten(loc['description']).trim() : '',
      genres: _optionalList(m['labels']).whereType<Map>().map((e) => _title(e['titles'], null)).where((s) => s.isNotEmpty).take(12).toList(),
      rating: tenPointScore(m['score']),
      alternativeNames: _optionalList(m['alternativeNames'])
          .whereType<Map>().map((item) => _text(item['content']))
          .where((name) => name.trim().isNotEmpty).take(6).toList(),
      creators: _optionalList(m['mainStaff']).whereType<Map>().map((staff) {
        final person = staff['person'];
        final name = person is Map ? _text(person['name']) : '';
        final roles = staff['roles'] is List
            ? (staff['roles'] as List).whereType<String>()
                .where((role) => role.isNotEmpty).take(5).toList()
            : <String>[];
        return MangaCreator(name: name, roles: roles);
      }).where((credit) => credit.name.isNotEmpty).take(12).toList(),
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

import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

/// Anonymous public API access only. No session, cookies or purchased chapters.
class ReMangaSource implements MangaSource {
  ReMangaSource({http.Client? client}) : _client = client;
  final http.Client? _client;
  static const _api = 'https://api.remanga.org/api/v2/';
  static const _site = 'https://remanga.org/';
  static const maxChapterPages = 5;
  @override String get key => 'remanga';
  @override String get name => 'ReManga';
  @override Map<String, String> get imageHeaders => const {'Referer': _site};

  static String _text(dynamic value) => value is String ? value.trim() : '';
  static String _id(dynamic value) {
    final id = value is int ? '$value' : _text(value);
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) ? id : '';
  }

  static String _image(dynamic value) {
    final path = _text(value);
    if (path.isEmpty) return '';
    try {
      final uri = Uri.parse(_site).resolve(path);
      if (uri.scheme == 'https' && uri.host.isNotEmpty &&
          uri.userInfo.isEmpty && !uri.hasFragment &&
          !RegExp(r'[\s\\]').hasMatch(path)) return uri.toString();
    } on FormatException { /* Invalid image URL. */ }
    return '';
  }

  static String _cover(Map value) {
    for (final field in ['cover', 'img']) {
      final raw = value[field];
      final candidates = raw is Map ? [raw['mid'], raw['high'], raw['low']] : [raw];
      for (final candidate in candidates) {
        final url = _image(candidate);
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$_api$path').replace(queryParameters: query);
    late http.Response response;
    try {
      final headers = {'Accept': 'application/json', ...imageHeaders};
      response = await (_client == null ? http.get(uri, headers: headers) :
          _client.get(uri, headers: headers)).timeout(const Duration(seconds: 18));
    } catch (_) {
      throw SourceException('ReManga: нет соединения или время ожидания истекло.');
    }
    if (response.statusCode != 200) {
      throw SourceException('ReManga: HTTP ${response.statusCode}. Источник недоступен; возможны ограничения региона или доступа.');
    }
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map<String, dynamic>) return data;
    } on FormatException { /* Report invalid payload below. */ }
    throw SourceException('ReManga: некорректный ответ API.');
  }

  static dynamic _content(Map data) => data['content'] ?? data['results'] ?? data;
  static List _list(Map data) {
    final value = _content(data);
    if (value is List) return value;
    throw SourceException('ReManga: некорректный список API.');
  }

  static String _title(Map data) {
    for (final field in ['main_name', 'rus_name', 'secondary_name', 'en_name']) {
      final value = _text(data[field]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  List<MangaEntry> _entries(Map data) => _list(data).whereType<Map>().map((item) {
    return MangaEntry(source: key, id: _id(item['dir'] ?? item['slug'] ?? item['id']),
        title: _title(item), coverUrl: _cover(item));
  }).where((item) => item.id.isNotEmpty && item.title.isNotEmpty).toList();

  @override Future<List<MangaEntry>> popular() async => _entries(await _get(
      'search/catalog/', {'count': '30', 'page': '1', 'ordering': '-rating'}));

  @override Future<List<MangaEntry>> search(String query) async {
    if (query.trim().isEmpty) return popular();
    return _entries(await _get('search/', {
      'query': query.trim(), 'count': '30', 'field': 'titles', 'page': '1',
    }));
  }

  // is_bought is deliberately ignored: there is no validated session.
  static bool _readable(Map chapter) =>
      (chapter['is_published'] == null || chapter['is_published'] == true) &&
      (chapter['is_locked'] == null || chapter['is_locked'] == false) &&
      (chapter['is_paid'] == null || chapter['is_paid'] == false ||
          chapter['is_free_today'] == true);

  @override Future<MangaDetail> detail(MangaEntry entry) async {
    if (_id(entry.id).isEmpty) throw SourceException('ReManga: некорректный адрес произведения.');
    final raw = _content(await _get('titles/${entry.id}/'));
    if (raw is! Map || raw['branches'] is! List) {
      throw SourceException('ReManga: некорректная карточка произведения.');
    }
    final branches = (raw['branches'] as List).whereType<Map>();
    final branch = branches.isEmpty ? '' : _id(branches.first['id']);
    final chapters = <Chapter>[];
    final seen = <String>{};
    if (branch.isNotEmpty) {
      for (var page = 1; page <= maxChapterPages; page++) {
        final data = await _get('titles/chapters/', {
          'branch_id': branch, 'page': '$page', 'count': '500',
          'ordering': '-index', 'user_data': '1',
        });
        final items = _list(data);
        var added = false;
        for (final item in items.whereType<Map>()) {
          final id = _id(item['id']);
          if (id.isEmpty || !seen.add(id)) continue;
          added = true;
          if (!_readable(item)) continue;
          final number = item['chapter'] is num ? '${item['chapter']}' : _text(item['chapter']);
          final subtitle = _text(item['name']);
          final tome = item['tome'];
          final volumeSuffix = tome == null || '$tome' == '0' ? '' : ' (т. $tome)';
          chapters.add(Chapter(id: id,
              name: 'Глава ${number.isEmpty ? '?' : number}${subtitle.isEmpty ? '' : ': $subtitle'}$volumeSuffix'));
        }
        if (!added || items.isEmpty || data['next'] == null || data['next'] == false || data['next'] == '') break;
      }
    }
    final title = _title(raw);
    return MangaDetail(
      entry: MangaEntry(source: key, id: entry.id, title: title.isEmpty ? entry.title : title,
          coverUrl: _cover(raw).isEmpty ? entry.coverUrl : _cover(raw)),
      chapters: chapters,
      description: html.parse(_text(raw['description'])).documentElement?.text.trim() ?? '',
      genres: (raw['genres'] is List ? raw['genres'] as List : const [])
          .whereType<Map>().map((g) => _text(g['name'])).where((g) => g.isNotEmpty).take(12).toList(),
    );
  }

  @override Future<List<PageImage>> pages(Chapter chapter) async {
    if (_id(chapter.id).isEmpty) throw SourceException('ReManga: некорректный адрес главы.');
    final raw = _content(await _get('titles/chapters/${chapter.id}/'));
    if (raw is! Map || !_readable(raw)) {
      throw SourceException('ReManga: глава недоступна без авторизации или оплаты.');
    }
    final result = <PageImage>[];
    void collect(dynamic value) {
      if (value is List) {
        for (final child in value) { collect(child); }
      } else {
        final url = _image(value is Map ? value['link'] ?? value['url'] : value);
        if (url.isEmpty) throw SourceException('ReManga: некорректный адрес изображения.');
        result.add(PageImage(url, headers: imageHeaders));
      }
    }
    if (raw['pages'] is List) collect(raw['pages']);
    if (result.isEmpty) throw SourceException('ReManga: публичные страницы главы недоступны.');
    return result;
  }
}

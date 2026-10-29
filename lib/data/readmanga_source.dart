import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

/// Reads public ReadManga pages. HTML selectors may break when the site changes.
/// No login tokens are gathered or bundled into the app.
class ReadMangaSource implements MangaSource {
  static const baseUrl = 'https://3.readmanga.ru';
  @override String get key => 'readmanga';
  @override String get name => 'ReadManga';
  @override Map<String, String> get imageHeaders => const {'Referer': '$baseUrl/'};
  Uri _absolute(String path) => Uri.parse(baseUrl).resolve(path);

  Future<String> _html(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != Uri.parse(baseUrl).host) {
      throw SourceException('Некорректный адрес страницы ReadManga');
    }
    late http.Response response;
    try {
      response = await http.get(uri, headers: {
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'ru-RU,ru;q=0.9',
        'Referer': '$baseUrl/',
      }).timeout(const Duration(seconds: 18));
    } catch (e) {
      throw SourceException('Нет соединения с ReadManga ($e)');
    }
    if (response.statusCode != 200) {
      throw SourceException('HTTP ${response.statusCode}. Сайт или зеркало недоступны.');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  static String _attr(dom.Element? node, List<String> names) {
    if (node == null) return '';
    for (final name in names) {
      final value = node.attributes[name];
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  String _image(String path) {
    if (path.isEmpty) return '';
    final uri = _absolute(path);
    return uri.scheme == 'https' ? uri.toString() : '';
  }

  List<MangaEntry> parseTiles(String html) {
    final doc = html_parser.parse(html);
    final results = <MangaEntry>[];
    for (final tile in doc.querySelectorAll('div.tile')) {
      final anchor = tile.querySelector('div.img a.non-hover') ??
          tile.querySelector('div.img a') ?? tile.querySelector('h3 a');
      final url = anchor?.attributes['href'] ?? '';
      if (url.isEmpty) continue;
      final img = tile.querySelector('div.img img') ?? tile.querySelector('img');
      final h3 = tile.querySelector('h3 a');
      final title = _attr(img, ['title']).trim().isNotEmpty
          ? _attr(img, ['title']).trim()
          : (_attr(h3, ['title']).isNotEmpty ? _attr(h3, ['title']) :
             (h3?.text.trim().isNotEmpty == true ? h3!.text.trim() : anchor?.text.trim() ?? ''));
      if (title.isEmpty) continue;
      final cover = _image(_attr(img, ['data-original', 'original', 'data-src', 'src']));
      results.add(MangaEntry(source: key, id: url, title: title, coverUrl: cover));
    }
    return results;
  }

  @override Future<List<MangaEntry>> popular() async {
    return parseTiles(await _html(_absolute('/list?sortType=RATING&offset=0')));
  }

  @override Future<List<MangaEntry>> search(String query) async {
    if (query.isEmpty) return popular();
    final uri = _absolute('/search/advancedResults?q=${Uri.encodeQueryComponent(query)}&offset=0&sortType=RATING');
    return parseTiles(await _html(uri));
  }

  @override Future<MangaDetail> detail(MangaEntry entry) async {
    final doc = html_parser.parse(await _html(_absolute(entry.id)));
    final h1 = doc.querySelector('h1.cr-hero-names__main') ??
        doc.querySelector('h1.names span.name') ?? doc.querySelector('h1');
    final name = h1?.text.trim().isNotEmpty == true ? h1!.text.trim() : entry.title;
    final cover = _image(_attr(doc.querySelector('img.cr-hero-poster__img') ??
      doc.querySelector('div.picture-fotorama img'), ['data-src', 'data-full', 'data-thumb', 'src']));
    final description = _attr(doc.querySelector('meta[itemprop="description"]'), ['content']).isNotEmpty
        ? _attr(doc.querySelector('meta[itemprop="description"]'), ['content'])
        : doc.querySelector('div.cr-description__content')?.text.trim() ?? '';
    final genres = doc.querySelectorAll('a[href*="/list/category/"]').map((e) => e.text.trim()).where((e) => e.isNotEmpty).toSet().take(12).toList();
    var rows = doc.querySelectorAll('tr.item-row');
    if (rows.isEmpty) rows = doc.querySelectorAll('div.chapters-link table tr, table.table-chapters tr');
    final chapters = <Chapter>[];
    for (final row in rows) {
      final a = row.querySelector('a.chapter-link.cp-l') ??
          row.querySelector('a.chapter-link') ?? row.querySelector('a[href*="/vol"]');
      if (a == null) continue;
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty || href.startsWith('#')) continue;
      final rawName = a.text.replaceAll(' новое', '').trim();
      if (rawName.isEmpty) continue;
      // Grouple often labels chapters "volume - chapter: subtitle".
      final match = RegExp(r'^(\d+)\s*[-—]\s*(\d+(?:\.\d+)?)\s*(?:[:—]\s*(.*))?$').firstMatch(rawName);
      final name = match == null ? rawName
          : 'Глава ${match.group(2)}${match.group(3)?.isNotEmpty == true ? ': ${match.group(3)}' : ''} (т. ${match.group(1)})';
      final suffix = href.contains('?') ? '&mtr=true' : '?mtr=true';
      chapters.add(Chapter(id: '$href$suffix', name: name));
    }
    return MangaDetail(entry: MangaEntry(source: key, id: entry.id, title: name,
        coverUrl: cover.isNotEmpty ? cover : entry.coverUrl),
        chapters: chapters, description: description, genres: genres);
  }

  /// Extract page metadata from the standard Grouple readerInit call. This is
  /// intentionally a narrow parser; fail clearly if ReadManga changes format.
  List<PageImage> parseReaderPages(String html) {
    var offset = html.indexOf('readerInit(');
    if (offset < 0) offset = html.indexOf('rm_h.initReader(');
    if (offset < 0) offset = html.indexOf('rm_h.readerDoInit(');
    if (offset < 0) return [];
    final begin = html.indexOf('[[', offset);
    final end = begin < 0 ? -1 : html.indexOf(']]', begin);
    if (begin < 0 || end < 0) return [];
    final body = html.substring(begin + 1, end + 1);
    final regex = RegExp(r'''\[\s*(['"])([^'"]*)\1\s*,\s*(['"])([^'"]*)\3\s*,\s*(['"])([^'"]*)\5\s*(?:,\s*[^\]]+)?\]''');
    final images = <PageImage>[];
    for (final match in regex.allMatches(body)) {
      final host = match.group(2) ?? '';
      final extra = match.group(4) ?? '';
      final path = match.group(6) ?? '';
      var url = host.isNotEmpty ? (extra.startsWith('/manga/') ? '$host$path' : '$host$extra$path') : path;
      if (url.startsWith('//')) url = 'https:$url';
      else if (url.startsWith('/')) url = '$baseUrl$url';
      if (!url.startsWith('https://')) continue;
      // Do not include removal placeholders in the actual reader.
      if (url.contains('/static/deleted1.png')) continue;
      images.add(PageImage(url, headers: imageHeaders));
    }
    return images;
  }

  @override Future<List<PageImage>> pages(Chapter chapter) async {
    return parseReaderPages(await _html(_absolute(chapter.id)));
  }
}

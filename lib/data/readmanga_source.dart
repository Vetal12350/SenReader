import 'chapter_scan_trace.dart';
import 'local_source_gate.dart';
import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:http/http.dart' as http;
import '../core/models.dart';
import '../core/source.dart';

/// Reads public ReadManga pages. HTML selectors may break when the site changes.
/// No login tokens are gathered or bundled into the app.
class ReadMangaSource implements MangaSource {
  ReadMangaSource({http.Client? client}) : _client = client;
  final http.Client? _client;
  // Keep a connection pool for repeated HTML fetches within one session.
  late final http.Client _session = _client ?? http.Client();

  // ReadManga currently links to the ZazaZa host from the GroupLe hub.
  // Keep only this public source as the canonical HTML origin.
  static const baseUrl = 'https://a.zazaza.me';
  static const legacyHost = '3.readmanga.ru';
  @override String get key => 'readmanga';
  @override String get name => 'ReadManga';
  // Grouple's current public ReadManga image endpoint expects a general
  // search-engine referer. A site referer is sometimes served a removed-page
  // image instead of manga content, even with a successful HTTP status.
  @override Map<String, String> get imageHeaders => const {
    'Referer': 'https://www.google.com/',
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
  /// Stored v1 favorites can contain the previous site's absolute URLs.
  /// Migrate only the known old source host, never arbitrary domains.
  Uri _absolute(String path) {
    final input = Uri.tryParse(path.trim());
    if (input == null || input.userInfo.isNotEmpty || input.hasFragment ||
        (input.hasScheme && input.scheme != 'https')) {
      throw SourceException('ReadManga: некорректная ссылка на главу.');
    }
    final base = Uri.parse(baseUrl);
    if (input.hasAuthority) {
      if (input.host != base.host && input.host != legacyHost) {
        throw SourceException('ReadManga: неизвестный адрес источника.');
      }
      if (input.port != 443) {
        throw SourceException('ReadManga: некорректный порт источника.');
      }
      if (input.host == legacyHost) {
        return base.replace(path: input.path, query: input.hasQuery ? input.query : null);
      }
    }
    final uri = base.resolveUri(input);
    if (uri.scheme != 'https' || uri.host != base.host ||
        uri.userInfo.isNotEmpty || uri.port != 443) {
      throw SourceException('ReadManga: некорректный адрес источника.');
    }
    return uri;
  }

  /// Allows migration checks and safe opening of prior bookmarked links.
  Uri canonicalChapterUri(String path) => _absolute(path);

  Future<String> _html(Uri uri) => _client != null ? _htmlOnce(uri) :
      LocalSourceGate.runScoped('readmanga', () => _htmlOnce(uri));

  Future<String> _htmlOnce(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != Uri.parse(baseUrl).host) {
      throw SourceException('Некорректный адрес страницы ReadManga');
    }
    late http.Response response;
    try {
      final headers = {
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'ru-RU,ru;q=0.9',
        'Referer': '$baseUrl/',
      };
      response = await ChapterScanTrace.stage('readmanga_http',
        () => _session.get(uri, headers: headers).timeout(const Duration(seconds: 18)));
    } catch (e) {
      throw SourceException('Нет соединения с ReadManga ($e)');
    }
    if (_client == null && LocalSourceGate.isBackgroundScan) {
      await LocalSourceGate('readmanga').response(
          response.statusCode, response.headers['retry-after']);
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
    try {
      // Public cover CDN images may be hosted separately from HTML.
      final uri = Uri.parse(baseUrl).resolve(path);
      return uri.scheme == 'https' && uri.host.isNotEmpty &&
          uri.userInfo.isEmpty && !uri.hasFragment
          ? uri.toString() : '';
    } on FormatException {
      return '';
    }
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

  /// Extract an upload date from the same chapter row as its link.
  /// ZazaZa displays DD.MM.YY on desktop; a missing/invalid date stays null.
  /// Never use the current time or the title's own publication date.
  static DateTime? chapterUploadDate(dom.Element row) {
    final candidates = row.querySelectorAll(
      'time, [datetime], [data-date], .chapter-date, .date, td');
    for (final node in candidates) {
      // A chapter title could include a date; only inspect its metadata cells.
      if (node.localName == 'td' &&
          node.querySelector('a.chapter-link, a[href*="/vol"]') != null) {
        continue;
      }
      for (final raw in [
        node.attributes['datetime'],
        node.attributes['data-date'],
        node.attributes['title'],
        node.text,
      ]) {
        if (raw == null || raw.trim().isEmpty) continue;
        final iso = sourceChapterDate(raw.trim());
        if (iso != null) return iso;
        final match = RegExp(
          r'\b([0-3]?[0-9])\.([01]?[0-9])\.([0-9]{4}|[0-9]{2})\b'
        ).firstMatch(raw);
        if (match == null) continue;
        final day = int.parse(match.group(1)!);
        final month = int.parse(match.group(2)!);
        final yearText = match.group(3)!;
        final year = yearText.length == 2
            ? 2000 + int.parse(yearText) : int.parse(yearText);
        if (year < 2000 || month < 1 || month > 12 ||
            day < 1 || day > 31) continue;
        final date = DateTime(year, month, day);
        if (date.year == year && date.month == month && date.day == day &&
            !date.isAfter(DateTime.now().add(const Duration(days: 2)))) {
          return date;
        }
      }
    }
    return null;
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
    // Only a declared public aggregate rating with an explicit scale is
    // trustworthy. Do not turn age restrictions or a count of votes into a
    // fictional 10-point score.
    final ratingNode = doc.querySelector('[itemprop="ratingValue"]');
    final bestNode = doc.querySelector('[itemprop="bestRating"]');
    final ratingValue = _attr(ratingNode, ['content']).isNotEmpty
        ? _attr(ratingNode, ['content']) : ratingNode?.text.trim();
    final bestValue = _attr(bestNode, ['content']).isNotEmpty
        ? _attr(bestNode, ['content']) : bestNode?.text.trim();
    final best = double.tryParse(bestValue ?? '');
    final score = best == null || best < 1 || best > 100 ? null
        : tenPointScore(ratingValue, max: best);

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
      chapters.add(Chapter(id: '$href$suffix', name: name,
          publishedAt: chapterUploadDate(row)));
    }
    return MangaDetail(entry: MangaEntry(source: key, id: entry.id, title: name,
        coverUrl: cover.isNotEmpty ? cover : entry.coverUrl),
        chapters: chapters, chaptersComplete: chapters.isNotEmpty,
        description: description, genres: genres,
        rating: score);
  }

  /// Extract page metadata from the standard Grouple readerInit call. This is
  /// intentionally a narrow parser; fail clearly if ReadManga changes format.
  List<PageImage> parseReaderPages(String html) {
    var offset = html.indexOf('readerInit(');
    if (offset < 0) offset = html.indexOf('rm_h.initReader(');
    if (offset < 0) offset = html.indexOf('rm_h.readerDoInit(');
    if (offset < 0) return [];
    // Modern reader scripts sometimes format nested arrays with whitespace
    // between brackets. Both "[[" and "[\n [" represent the same page list.
    final outer = RegExp(r'\[\s*\[').firstMatch(html.substring(offset));
    if (outer == null) return [];
    final begin = offset + outer.start;
    final close = RegExp(r'\]\s*\]').firstMatch(html.substring(begin));
    if (close == null) return [];
    final end = begin + close.start;
    final body = html.substring(begin + 1, end + 1);
    final regex = RegExp(r'''\[\s*(['"])([^'"]*)\1\s*,\s*(['"])([^'"]*)\3\s*,\s*(['"])([^'"]*)\5\s*(?:,\s*[^\]]+)?\]''');
    final images = <PageImage>[];
    for (final match in regex.allMatches(body)) {
      final host = match.group(2) ?? '';
      final extra = match.group(4) ?? '';
      final path = match.group(6) ?? '';
      // GroupLe's second tuple component may be a URL prefix.
      var url = extra.isEmpty && path.startsWith('/static/')
          ? '$baseUrl$path'
          : (extra.endsWith('/manga/') ? '$host$path' : '$extra$host$path');
      if (!url.contains('://')) url = 'https:$url';
      url = url.replaceFirst('//resh', '//h');
      if (url.contains('one-way.work')) url = url.split('?').first;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
          uri.userInfo.isNotEmpty || uri.hasFragment) continue;
      // Do not include removal placeholders in the actual reader.
      if (_isPlaceholderUrl(url)) continue;
      images.add(PageImage(url, headers: imageHeaders));
    }
    return images;
  }

  static bool _isPlaceholderUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return true;
    final path = uri.path.toLowerCase();
    // The live public chapter page also references hashed placeholder
    // assets such as /static/deleted1-<digest>.png.
    return RegExp(r'/(?:deleted1?|removed|censored)(?:-[a-f0-9]{8,})?\.png$')
        .hasMatch(path);
  }

  /// Read only a small prefix of the image response to recognize identical
  /// CDN-hosted removal cards masquerading as real manga pages. No full
  /// chapter images are downloaded by this preflight.
  Future<List<int>> _sampleImage(http.Client client, PageImage page) =>
      _client != null ? _sampleImageOnce(client, page) :
      LocalSourceGate.runScoped('readmanga',
          () => _sampleImageOnce(client, page));

  Future<List<int>> _sampleImageOnce(http.Client client, PageImage page) async {
    final uri = Uri.tryParse(page.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw SourceException('ReadManga: некорректная ссылка на страницу главы.');
    }
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll(page.headers);
      final response = await client.send(request)
          .timeout(const Duration(seconds: 15));
      if (_client == null && LocalSourceGate.isBackgroundScan) {
        await LocalSourceGate('readmanga').response(
            response.statusCode, response.headers['retry-after']);
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw SourceException('ReadManga: изображение недоступно (HTTP ${response.statusCode}).');
      }
      final type = response.headers['content-type']?.toLowerCase() ?? '';
      if (type.isNotEmpty && !type.startsWith('image/')) {
        throw SourceException('ReadManga: сервер вернул не изображение.');
      }
      const sampleLimit = 8192;
      final bytes = <int>[];
      await for (final chunk in response.stream
          .timeout(const Duration(seconds: 15))) {
        final remaining = sampleLimit - bytes.length;
        if (remaining <= 0) break;
        bytes.addAll(chunk.take(remaining));
        if (bytes.length >= sampleLimit) break;
      }
      if (bytes.isEmpty) {
        throw SourceException('ReadManga: изображение пустое.');
      }
      return bytes;
    } on SourceException {
      rethrow;
    } catch (_) {
      throw SourceException('ReadManga: не удалось проверить доступность изображения.');
    }
  }

  static bool _samePrefix(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _checkImages(List<PageImage> images) async {
    if (images.isEmpty) {
      throw SourceException('ReadManga: главы нет в публичном доступе (удалена или закрыта).');
    }
    if (images.length >= 2 &&
        images.take(3).map((image) => image.url).toSet().length == 1) {
      throw SourceException('ReadManga: сервер отдаёт одинаковую заглушку вместо страниц.');
    }
    // Use the same bounded connection pool as the HTML request; keep the
    // existing safety preflight, but avoid extra TLS handshakes per chapter.
    final sampled = await Future.wait(
        images.take(3).map((image) => _sampleImage(_session, image)));
    if (sampled.length >= 2 && sampled.every(
        (bytes) => _samePrefix(sampled.first, bytes))) {
      throw SourceException(
          'ReadManga: вместо страниц возвращается одинаковая картинка — '
          'возможно, манга удалена на этом зеркале.');
    }
  }

  @override Future<List<PageImage>> pages(Chapter chapter) async {
    final images = parseReaderPages(await _html(_absolute(chapter.id)));
    await _checkImages(images);
    return images;
  }
}

